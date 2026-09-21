# frozen_string_literal: true

# Rule-based noindex flags for stale / thin topics.
#
# Background: docs/plans/DISCOURSE-THIN-CONTENT-NOINDEX.md in the rumx-hugo
# repo (SEO-agency ticket "Community Thin Content", 2026-09-21). Discourse core
# has no per-topic noindex, so this module computes a flag once a day and
# stores it as topic custom fields; NoindexServing turns the flag into an
# X-Robots-Tag header, SitemapExtension drops flagged topics from the sitemap.
#
# A topic is flagged when ONE of these holds
#   about  it is the description topic of its category (categories.topic_id)
#   thin   words(regular, non-deleted posts) < thin_max_words
#          AND last_activity older than thin_min_age_days
#   stale  last_activity older than stale_min_age_days
#          AND human views in the last 90 days < stale_max_views_90d
#          (< unflag_min_views_90d while already flagged: hysteresis)
# and NONE of these holds
#   guard  a visit from a search-engine referrer host in the last 90 days
#          (incoming_links -> incoming_referers -> incoming_domains)
#   exempt topic id listed in rumx_noindex_exempt_topic_ids
#
# last_activity = GREATEST(topics.last_posted_at, MAX(post_revisions.created_at
# by a real user)) so an edit of an old post counts as activity, not only a
# new post. Revisions by the system user (id -1) are ignored on purpose:
# posts.last_version_at would make 307 topics "active" because of the
# rum-x.com -> rumx.com link remap of 2026-05-07.
#
# Views come from topic_view_stats, which core increments only for browser
# page views (lib/middleware/request_tracker.rb, tracks_browser_page_view?);
# crawlers never count. A 90-day window is used because 30 days flickers
# (measured 2026-09-21: 414 zero-view topics in 30 d vs 168 in 90 d).
#
# Everything here is pure computation + custom-field writes. No HTTP, no
# SiteSetting reads outside the public entry points, so validate_live.rb can
# exercise it read-only with stubbed settings.
module ::DiscourseRUMXUTM
  module Noindex
    FIELD = "rumx_noindex"
    REASON_FIELD = "rumx_noindex_reason"
    SINCE_FIELD = "rumx_noindex_since"
    REASONS = %w[about thin stale].freeze
    RULE_VERSION = 1
    PLUGIN_STORE_NAME = "discourse-rumx-utm"
    LAST_RUN_KEY = "noindex_last_run"
    RUN_KEY_PREFIX = "noindex_run:"
    MAX_DATA_AGE_DAYS = 2

    Decision = Struct.new(:topic_id, :flag, :reason, :flagged_before, :guarded, :exempt,
                          :words, :views90, :last_activity, keyword_init: true)

    # One query, all public topics. `:flagged` is the CURRENT flag so the
    # stale rule can apply the hysteresis threshold.
    ROWS_SQL = <<~SQL
      WITH pub AS (
        SELECT t.id, t.last_posted_at, t.created_at, (c.topic_id = t.id) AS about_topic
        FROM topics t
        JOIN categories c ON c.id = t.category_id
        WHERE t.deleted_at IS NULL
          AND t.visible
          AND t.archetype = 'regular'
          AND NOT c.read_restricted
      ),
      words AS (
        SELECT p.topic_id, COALESCE(SUM(p.word_count), 0) AS words
        FROM posts p
        JOIN pub ON pub.id = p.topic_id
        WHERE p.deleted_at IS NULL AND p.post_type = 1
        GROUP BY p.topic_id
      ),
      edits AS (
        SELECT p.topic_id, MAX(pr.created_at) AS last_edit
        FROM post_revisions pr
        JOIN posts p ON p.id = pr.post_id
        JOIN pub ON pub.id = p.topic_id
        WHERE pr.user_id > 0
          AND p.deleted_at IS NULL AND p.post_type = 1
        GROUP BY p.topic_id
      ),
      views AS (
        SELECT s.topic_id, SUM(s.anonymous_views + s.logged_in_views) AS views90
        FROM topic_view_stats s
        JOIN pub ON pub.id = s.topic_id
        WHERE s.viewed_at > CURRENT_DATE - 90
        GROUP BY s.topic_id
      ),
      guard AS (
        SELECT DISTINCT p.topic_id
        FROM incoming_links l
        JOIN posts p ON p.id = l.post_id
        JOIN pub ON pub.id = p.topic_id
        JOIN incoming_referers r ON r.id = l.incoming_referer_id
        JOIN incoming_domains d ON d.id = r.incoming_domain_id
        WHERE l.created_at > NOW() - INTERVAL '90 days'
          AND (lower(d.name) IN (:domains) OR lower(d.name) LIKE ANY (ARRAY[:suffixes]))
      ),
      flagged AS (
        SELECT topic_id FROM topic_custom_fields WHERE name = :field AND value = 't'
      )
      SELECT pub.id AS topic_id,
             pub.about_topic,
             COALESCE(w.words, 0) AS words,
             GREATEST(COALESCE(pub.last_posted_at, pub.created_at), e.last_edit) AS last_activity,
             COALESCE(v.views90, 0) AS views90,
             (g.topic_id IS NOT NULL) AS guarded,
             (f.topic_id IS NOT NULL) AS flagged
      FROM pub
      LEFT JOIN words w ON w.topic_id = pub.id
      LEFT JOIN edits e ON e.topic_id = pub.id
      LEFT JOIN views v ON v.topic_id = pub.id
      LEFT JOIN guard g ON g.topic_id = pub.id
      LEFT JOIN flagged f ON f.topic_id = pub.id
    SQL

    class << self
      # ---- settings (single place that reads SiteSetting) ----
      def settings
        {
          thin_max_words: SiteSetting.rumx_noindex_thin_max_words.to_i,
          thin_min_age_days: SiteSetting.rumx_noindex_thin_min_age_days.to_i,
          stale_min_age_days: SiteSetting.rumx_noindex_stale_min_age_days.to_i,
          stale_max_views_90d: SiteSetting.rumx_noindex_stale_max_views_90d.to_i,
          unflag_min_views_90d: SiteSetting.rumx_noindex_unflag_min_views_90d.to_i,
          guard_domains: split_list(SiteSetting.rumx_noindex_guard_referrer_domains).map(&:downcase),
          exempt_topic_ids: split_list(SiteSetting.rumx_noindex_exempt_topic_ids).map(&:to_i).reject(&:zero?),
          max_new_flags_per_run: SiteSetting.rumx_noindex_max_new_flags_per_run.to_i,
        }
      end

      def split_list(value)
        value.to_s.split("|").map(&:strip).reject(&:empty?)
      end

      # ---- computation (read-only) ----
      def decisions(config = settings, now: Time.zone.now)
        domains = config[:guard_domains].presence || ["-"]
        rows = DB.query(
          ROWS_SQL,
          domains: domains,
          suffixes: domains.map { |d| "%.#{d}" },
          field: FIELD,
        )
        exempt = config[:exempt_topic_ids].to_set
        rows.map { |row| decide(row, config, exempt, now) }
      end

      def decide(row, config, exempt, now)
        last_activity = row.last_activity
        age_days = last_activity ? (now - last_activity) / 86_400.0 : Float::INFINITY
        thin = row.words < config[:thin_max_words] && age_days > config[:thin_min_age_days]
        stale_threshold = row.flagged ? config[:unflag_min_views_90d] : config[:stale_max_views_90d]
        stale = age_days > config[:stale_min_age_days] && row.views90 < stale_threshold
        reason =
          if row.about_topic then "about"
          elsif thin then "thin"
          elsif stale then "stale"
          end
        is_exempt = exempt.include?(row.topic_id)
        Decision.new(
          topic_id: row.topic_id,
          flag: !!reason && !row.guarded && !is_exempt,
          reason: reason,
          flagged_before: row.flagged,
          guarded: row.guarded,
          exempt: is_exempt,
          words: row.words,
          views90: row.views90,
          last_activity: last_activity,
        )
      end

      def summarize(decisions)
        wanted = decisions.select(&:flag)
        {
          public_topics: decisions.size,
          flagged_before: decisions.count(&:flagged_before),
          wanted: wanted.size,
          by_reason: REASONS.to_h { |r| [r, wanted.count { |d| d.reason == r }] },
          guarded_away: decisions.count { |d| d.reason && d.guarded && !d.exempt },
          exempt_away: decisions.count { |d| d.reason && d.exempt },
          to_add: wanted.count { |d| !d.flagged_before },
          to_remove: decisions.count { |d| d.flagged_before && !d.flag },
        }
      end

      def data_fresh?
        views_max = TopicViewStat.maximum(:viewed_at)
        links_max = IncomingLink.maximum(:created_at)
        fresh = views_max.present? && views_max >= Date.today - MAX_DATA_AGE_DAYS &&
          links_max.present? && links_max >= MAX_DATA_AGE_DAYS.days.ago
        [fresh, { topic_view_stats_max: views_max&.to_s, incoming_links_max: links_max&.iso8601 }]
      end

      # ---- the run (called by the scheduled job and by hand) ----
      # initial: true  -> ignore the drift brake (first run / re-baseline)
      # dry_run: true  -> compute + audit, write nothing
      def recalc!(initial: false, dry_run: false)
        DistributedMutex.synchronize("rumx_noindex_recalc", validity: 30.minutes) do
          started = Time.zone.now
          fresh, freshness = data_fresh?
          unless fresh
            Rails.logger.warn("discourse-rumx-utm noindex: source data stale (#{freshness.inspect}) — run skipped, flags kept")
            return { skipped: "stale_data", freshness: freshness }
          end

          config = settings
          all = decisions(config, now: started)
          summary = summarize(all)

          add = all.select { |d| d.flag && !d.flagged_before }
          remove_ids = all.select { |d| d.flagged_before && !d.flag }.map(&:topic_id)
          # Flags on topics that left the public set (deleted, unlisted, moved
          # into a restricted category) are removed too.
          public_ids = all.map(&:topic_id).to_set
          orphan_ids = TopicCustomField.where(name: FIELD).pluck(:topic_id).reject { |id| public_ids.include?(id) }
          remove_ids |= orphan_ids
          kept = all.select { |d| d.flag && d.flagged_before }

          held_back = false
          if !initial && add.size > config[:max_new_flags_per_run]
            held_back = true
            Rails.logger.warn(
              "discourse-rumx-utm noindex: #{add.size} new flags exceed rumx_noindex_max_new_flags_per_run=" \
                "#{config[:max_new_flags_per_run]} — additions held back, removals applied",
            )
          end
          to_add = held_back ? [] : add

          write!(to_add, remove_ids, kept, started.to_date) unless dry_run

          run = {
            run_id: started.utc.iso8601,
            finished_at: Time.zone.now.utc.iso8601,
            rule_version: RULE_VERSION,
            initial: initial,
            dry_run: dry_run,
            held_back: held_back,
            enabled: SiteSetting.rumx_noindex_enabled,
            settings: config.except(:exempt_topic_ids).merge(exempt_count: config[:exempt_topic_ids].size),
            freshness: freshness,
            summary: summary.merge(orphans_removed: orphan_ids.size),
            added: to_add.map(&:topic_id),
            removed: remove_ids,
          }
          PluginStore.set(PLUGIN_STORE_NAME, "#{RUN_KEY_PREFIX}#{run[:run_id]}", run)
          PluginStore.set(PLUGIN_STORE_NAME, LAST_RUN_KEY, run[:run_id])
          Rails.logger.info(
            "discourse-rumx-utm noindex run #{run[:run_id]}#{dry_run ? " (dry run)" : ""}: " \
              "+#{to_add.size} -#{remove_ids.size} held=#{held_back} total_wanted=#{summary[:wanted]} " \
              "(#{summary[:by_reason].map { |k, v| "#{k}=#{v}" }.join(" ")})",
          )
          run
        end
      end

      def write!(to_add, remove_ids, kept, today)
        names = [FIELD, REASON_FIELD, SINCE_FIELD]
        Topic.transaction do
          TopicCustomField.where(name: names, topic_id: remove_ids).delete_all if remove_ids.any?
          if to_add.any?
            add_ids = to_add.map(&:topic_id)
            TopicCustomField.where(name: names, topic_id: add_ids).delete_all
            TopicCustomField.insert_all(
              to_add.flat_map do |d|
                [
                  { topic_id: d.topic_id, name: FIELD, value: "t" },
                  { topic_id: d.topic_id, name: REASON_FIELD, value: d.reason },
                  { topic_id: d.topic_id, name: SINCE_FIELD, value: today.iso8601 },
                ]
              end,
            )
          end
          # reason may change while the flag stays (e.g. thin -> stale)
          kept.group_by(&:reason).each do |reason, ds|
            TopicCustomField
              .where(name: REASON_FIELD, topic_id: ds.map(&:topic_id))
              .where.not(value: reason)
              .update_all(value: reason, updated_at: Time.zone.now)
          end
        end
        invalidate_sitemap_cache! if to_add.any? || remove_ids.any?
      end

      # SitemapController caches each page for 24 h under this key.
      def invalidate_sitemap_cache!
        return unless defined?(::Sitemap)
        ::Sitemap.all.each do |s|
          Discourse.cache.delete("sitemap/#{s.name}/#{SiteSetting.sitemap_page_size}")
        end
      rescue => e
        Rails.logger.warn("discourse-rumx-utm noindex: sitemap cache invalidation failed: #{e.class}: #{e.message}")
      end

      def flagged?(topic)
        return false if topic.nil?
        topic.custom_fields[FIELD] == true
      end

      def flagged_topic_ids
        TopicCustomField.where(name: FIELD, value: "t").select(:topic_id)
      end
    end
  end
end
