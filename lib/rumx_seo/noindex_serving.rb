# frozen_string_literal: true

# Turns the noindex flags (Noindex) into an X-Robots-Tag response header.
# Header only, no <meta> — one output path, one truth. Google honours the
# header for HTML; the agency's crawler (Screaming Frog) reads it into its
# "X-Robots-Tag 1" column.
#
# The header is MERGED, never overwritten: core may already have set e.g.
# "noindex, nofollow" (unlisted topics, application_controller#add_noindex_header).
module ::DiscourseRUMXUTM
  module NoindexServing
    # Every ListController action that renders a category list page. Verified
    # against ListController.action_methods on 2026-09-21 (Discourse
    # tests-passed); validate_live.rb re-checks the list on every run so a
    # core change shows up as a failed check, not as a silent gap.
    # category_feed (RSS) is deliberately excluded.
    CATEGORY_LIST_ACTIONS = %w[
      category_default category_none_default
      category_latest category_none_latest
      category_new category_none_new
      category_unread category_none_unread
      category_unseen category_none_unseen
      category_read category_none_read
      category_posted category_none_posted
      category_bookmarks category_none_bookmarks
      category_hot category_none_hot
      category_votes category_none_votes
      category_top category_none_top
      category_top_all category_none_top_all
      category_top_daily category_none_top_daily
      category_top_weekly category_none_top_weekly
      category_top_monthly category_none_top_monthly
      category_top_quarterly category_none_top_quarterly
      category_top_yearly category_none_top_yearly
    ].freeze

    class << self
      def enabled?
        SiteSetting.rumx_noindex_enabled
      end

      # Adds "noindex" to X-Robots-Tag, keeping whatever directives are there.
      def add_noindex!(response)
        current = response.headers["X-Robots-Tag"].to_s.split(",").map(&:strip).reject(&:empty?)
        return if current.map(&:downcase).include?("noindex")
        response.headers["X-Robots-Tag"] = (current + ["noindex"]).join(", ")
      end

      def topic_flagged?(topic)
        enabled? && ::DiscourseRUMXUTM::Noindex.flagged?(topic)
      end

      def category_flagged?(category)
        return false if !enabled? || category.nil?
        category_ids.include?(category.id)
      end

      def category_ids
        SiteSetting.rumx_noindex_category_ids.to_s.split("|").map(&:to_i).reject(&:zero?)
      end

      # after_action bodies. `controller` is the live controller instance.
      def apply_topic!(controller)
        request = controller.request
        return unless request.get? || request.head?
        topic = controller.instance_variable_get(:@topic_view)&.topic
        add_noindex!(controller.response) if topic_flagged?(topic)
      rescue => e
        Rails.logger.warn("discourse-rumx-utm noindex: topic header skipped: #{e.class}: #{e.message}")
      end

      def apply_category!(controller)
        request = controller.request
        return unless request.get? || request.head?
        category = controller.instance_variable_get(:@category)
        add_noindex!(controller.response) if category_flagged?(category)
      rescue => e
        Rails.logger.warn("discourse-rumx-utm noindex: category header skipped: #{e.class}: #{e.message}")
      end
    end
  end

  # Sitemap: flagged topics leave sitemap_1.xml / sitemap_recent.xml. Core's
  # Sitemap#sitemap_topics is private and has no plugin modifier, hence the
  # prepend. `where.not` composes onto the paginated relation lazily; with one
  # sitemap page (1,914 topics < sitemap_page_size 10,000) the page boundary
  # is irrelevant. validate_live.rb checks that the method still exists and
  # that the live XML equals (unfiltered set − flagged ids).
  module SitemapExtension
    private

    def sitemap_topics
      scope = super
      return scope unless SiteSetting.rumx_noindex_enabled
      scope.where.not(id: ::DiscourseRUMXUTM::Noindex.flagged_topic_ids)
    end
  end
end
