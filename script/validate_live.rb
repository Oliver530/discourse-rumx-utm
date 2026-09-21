# Live validation of plugin.rb against the running Discourse — run this after
# every plugin change (before /admin/upgrade, pointing at the new file) and
# after every Discourse core upgrade (pointing at the deployed file), because
# TopicLinkClickExtension prepends a core model method that core may change.
#
#   scp -r . root@<droplet>:/tmp/plugin_new          # whole plugin dir (lib/, config/)
#   ssh root@<droplet> 'docker rm -f x 2>/dev/null; docker cp /tmp/plugin_new app:/tmp/plugin_new;
#     docker exec app bash -c "cd /var/www/discourse && su discourse -c \
#       \"PLUGIN_RB=/tmp/plugin_new/plugin.rb bundle exec rails runner -e production /tmp/plugin_new/script/validate_live.rb\""'
#
# PLUGIN_RB=/var/www/discourse/plugins/discourse-rumx-utm/plugin.rb validates
# the deployed tree instead. Exit 0 = all checks passed. lib/**/*.rb next to
# plugin.rb are loaded first; site settings the running core does not know yet
# (config/settings.yml of the new version) are stubbed with their defaults.
#
# Loads the plugin body into THIS rails-runner process only (the unicorn
# workers are untouched), stubs `on(...)` so the event handlers can be invoked
# directly, and touches the DB only inside one transaction that is rolled
# back. Expect "already initialized constant" warnings: the module is reopened.
plugin_path = ENV.fetch("PLUGIN_RB", "/tmp/plugin_new/plugin.rb")
plugin_dir = File.dirname(plugin_path)
src = File.read(plugin_path)

# New-version site settings are not in the running core yet: stub defaults.
settings_yml = File.join(plugin_dir, "config", "settings.yml")
if File.exist?(settings_yml)
  require "yaml"
  YAML.load_file(settings_yml).each_value do |group|
    group.each do |name, spec|
      next if SiteSetting.respond_to?(name)
      default = spec.is_a?(Hash) ? spec["default"] : spec
      SiteSetting.define_singleton_method(name) { default }
      puts "  (stubbed SiteSetting.#{name} = #{default.inspect} — not deployed yet)"
    end
  end
end
Dir[File.join(plugin_dir, "lib", "**", "*.rb")].sort.each { |f| load f }
body = src[/after_initialize do\n(.*)\nend\s*\z/m, 1] or raise "could not extract after_initialize body"
handlers = {}
ctx = Object.new
ctx.define_singleton_method(:on) { |evt, &blk| handlers[evt] = blk }
ctx.define_singleton_method(:register_post_custom_field_type) { |name, type, **opts| ::Post.register_custom_field_type(name, type, **opts) }
ctx.define_singleton_method(:register_topic_custom_field_type) { |name, type, **opts| ::Topic.register_custom_field_type(name, type, **opts) }
ctx.define_singleton_method(:reloadable_patch) { |&blk| blk.call(nil) }
ctx.instance_eval(body, plugin_path, 8)

fails = 0
check = ->(name, cond, extra = nil) {
  puts "#{cond ? 'PASS' : 'FAIL'}  #{name}#{extra ? "  -> #{extra}" : ''}"
  fails += 1 unless cond
}


check.("handlers registered: post_process_cooked + post_process_localized_cooked",
       handlers.key?(:post_process_cooked) && handlers.key?(:post_process_localized_cooked), handlers.keys.inspect)

# ---------- 1. fresh cook: linkify + UTM + Market Radar preservation ----------
html = <<~HTML
  <p>Für mich war der RX7295 etwas besser als rx43.</p>
  <p><a href="https://www.amazon.de/dp/B000?tag=rumx-21">Amazon</a></p>
  <p><a href="https://rumx.com/de/rums/43/?utm_source=forum&amp;utm_medium=post&amp;utm_campaign=market_radar&amp;utm_content=RX43">Smith &amp; Cross</a></p>
  <p><a href="https://rumx.com/en/rums/22143/?utm_content=RX22143">Foursquare</a></p>
  <p><a href="https://rumx.com/en/rums/9198/">typed clean rumx link</a></p>
  <p><a href="https://www.rumx.com/best-rums">www no slash</a></p>
  <aside class="quote"><blockquote>quoted RX368 must not link</blockquote></aside>
HTML
doc = Loofah.html5_fragment(html)
handlers[:post_process_cooked].call(doc, nil)
out = doc.to_html
check.("RX7295 linkified clean /en/", out.include?('<a href="https://rumx.com/en/rums/7295/">RX7295</a>'))
check.("rx43 (lowercase) linkified", out.include?('<a href="https://rumx.com/en/rums/43/">rx43</a>'))
check.("RX368 inside aside.quote NOT linkified", !out.include?('rums/368/'))
amz = doc.css("a").find { |a| a["href"].include?("amazon") }["href"]
check.("amazon link gets forum UTM", amz.include?("utm_source=rumx") && amz.include?("utm_campaign=rumx-forum") && amz.include?("tag=rumx-21"), amz)
mr = doc.css("a").find { |a| a["href"].include?("rums/43/") && a["href"].include?("utm") }["href"]
check.("Market Radar UTM PRESERVED (campaign=market_radar, source=forum)",
       mr.include?("utm_campaign=market_radar") && mr.include?("utm_source=forum") && mr.include?("utm_medium=post") && mr.include?("utm_content=RX43"), mr)
fq = doc.css("a").find { |a| a["href"].include?("rums/22143/") }["href"]
check.("rumx link with only utm_content: forum defaults FILLED, content kept",
       fq.include?("utm_content=RX22143") && fq.include?("utm_source=rumx") && fq.include?("utm_campaign=rumx-forum"), fq)
tc = doc.css("a").find { |a| a["href"].start_with?("https://rumx.com/en/rums/9198/") }["href"]
check.("author-typed CLEAN rumx RX-shaped link is left untouched (no UTM)", tc == "https://rumx.com/en/rums/9198/", tc)
ww = doc.css("a").find { |a| a["href"].include?("best-rums") }["href"]
check.("www + missing slash canonicalized and UTM'd", ww.start_with?("https://rumx.com/best-rums/?"), ww)

# ---------- 2. idempotence: re-run both passes on the ALREADY processed doc ----------
before = doc.to_html
handlers[:post_process_localized_cooked].call(doc, nil, nil)
after = doc.to_html
check.("second pass is a no-op (RX anchors stay clean, no nested anchors, no double UTM)", before == after)
check.("no nested anchors", doc.css("a a").empty?)

# ---------- 3. localized handler on a fresh doc ----------
ldoc = Loofah.html5_fragment("<p>Übersetzt: RX5934 und RX368.</p>")
handlers[:post_process_localized_cooked].call(ldoc, nil, nil)
check.("localized handler linkifies", ldoc.css("a").map { |a| a["href"] } == ["https://rumx.com/en/rums/5934/", "https://rumx.com/en/rums/368/"], ldoc.to_html)

# ---------- 4. TopicLinkClick prepend ----------
check.("TopicLinkClick prepended", ::TopicLinkClick.singleton_class.ancestors.include?(::DiscourseRUMXUTM::TopicLinkClickExtension))
# public topic only: TopicLinkClick.create_from refuses clicks the (anonymous) guardian cannot see
tl = TopicLink.joins(topic: :category).where("url ~ ?", '^https://rumx\.com/en/rums/[0-9]+/$').where.not(post_id: nil)
  .where(topics: { archetype: "regular", deleted_at: nil, visible: true }).where(categories: { read_restricted: false }).order(id: :desc).first
rx_id = tl.url[%r{/rums/(\d+)/}, 1]
post = tl.post
puts "  using topic_link #{tl.id} post #{tl.post_id} topic #{tl.topic_id} url #{tl.url} (author user #{post.user_id})"
ip = "203.0.113.#{rand(2..250)}"
rkey = "link-clicks:#{tl.id}:#{ip}"
Discourse.redis.del(rkey)
created = nil
ActiveRecord::Base.transaction do
  n0 = TopicLinkClick.where(topic_link_id: tl.id).count
  ret = TopicLinkClick.create_from(url: "https://rumx.com/de/rums/#{rx_id}/", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: ip, user_id: nil, guardian: Guardian.new)
  n1 = TopicLinkClick.where(topic_link_id: tl.id).count
  created = (n1 == n0 + 1)
  check.("/de/ click counted against the /en/ TopicLink (anon, fresh ip)", created, "return=#{ret.inspect} before=#{n0} after=#{n1}")
  # author-typed exact /de/ link present in the post -> must NOT be normalized away
  own = TopicLink.create!(topic_id: tl.topic_id, post_id: tl.post_id, user_id: post.user_id, domain: "rumx.com", url: "https://rumx.com/fr/rums/#{rx_id}/", internal: false, link_topic_id: nil, reflection: false, clicks: 0, title: nil, crawled_at: nil, quote: false, extension: nil)
  ip2 = "203.0.113.#{rand(2..250)}"
  Discourse.redis.del("link-clicks:#{own.id}:#{ip2}")
  TopicLinkClick.create_from(url: "https://rumx.com/fr/rums/#{rx_id}/", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: ip2, user_id: nil, guardian: Guardian.new)
  check.("exact /fr/ TopicLink in the post wins over normalization", TopicLinkClick.where(topic_link_id: own.id).count == 1)
  Discourse.redis.del("link-clicks:#{own.id}:#{ip2}")
  raise ActiveRecord::Rollback
end
Discourse.redis.del(rkey)
check.("transaction rolled back (no new click rows persisted)", TopicLinkClick.where(topic_link_id: tl.id, ip_address: ip).count == 0)
# pass-through: non-matching URL must not raise
begin
  TopicLinkClick.create_from(url: "https://rumx.com/de/rums/#{rx_id}/?utm_source=x", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: "203.0.113.1", user_id: nil, guardian: Guardian.new)
  TopicLinkClick.create_from(url: "https://example.org/x", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: "203.0.113.1", user_id: nil, guardian: Guardian.new)
  check.("non-matching urls pass through without raising", true)
rescue => e
  check.("non-matching / malformed urls pass through without raising", false, "#{e.class}: #{e.message}")
end

# ---------- 5. Translation freshness: digest-based show_translated_post? ----------
puts
puts "-- translation freshness --"
tf = ::DiscourseRUMXUTM::TranslationFreshness
check.("ContentLocalization prepended", ::ContentLocalization.singleton_class.ancestors.include?(::DiscourseRUMXUTM::ContentLocalizationExtension))
check.("PostLocalizer prepended (lock + digest recording + dedupe)", ::DiscourseAi::Translation::PostLocalizer.singleton_class.ancestors.include?(::DiscourseRUMXUTM::PostLocalizerExtension))
check.("digest custom fields registered for supported locales", tf.supported_locales.all? { |l| ::Post.get_custom_field_descriptor(tf.field_name(l)).type == :string }, tf.supported_locales.inspect)
check.("TopicView preloads the digest fields", (::TopicView.allowed_post_custom_fields(nil, nil) & tf.supported_locales.map { |l| tf.field_name(l) }).size == tf.supported_locales.size)
sample_raw = "Für mich war der RX7295 „etwas“ besser 🥃\n\n* 5cl: 19€"
check.("Ruby MD5 == Postgres md5() (SQL predicate parity, incl. UTF-8)", DB.query_single("SELECT md5(?)", sample_raw).first == tf.digest(sample_raw))

core_show = ::ContentLocalization.method(:show_translated_post?).super_method
fresh_loc = PostLocalization.joins(:post).where("post_localizations.post_version = posts.version").where(locale: "de").where("posts.deleted_at IS NULL AND posts.locale = 'en' AND posts.user_id > 0").order("posts.updated_at desc").first
# A real stale legacy row (translation behind the post, no digest, language differs from the post)
# may not exist once the reconciler has done its work; then synthesize one inside the transaction below.
stale_loc = PostLocalization.joins(:post).where("post_localizations.post_version < posts.version").where(locale: "de")
  .where("posts.deleted_at IS NULL AND posts.locale <> 'de' AND posts.user_id > 0")
  .where("NOT EXISTS (SELECT 1 FROM post_custom_fields f WHERE f.post_id = posts.id AND f.name = ?)", ::DiscourseRUMXUTM::TranslationFreshness.field_name("de"))
  .order("posts.updated_at desc").first
stale_synthetic = false
if stale_loc.nil? && fresh_loc
  # take another fresh EN post with a de localization and pretend the post moved on (rolled back at the end)
  cand = PostLocalization.joins(:post).where("post_localizations.post_version = posts.version").where(locale: "de").where("posts.deleted_at IS NULL AND posts.locale = 'en' AND posts.user_id > 0").where.not(post_id: fresh_loc.post_id).order("posts.updated_at desc").first
  if cand
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    PostCustomField.where(post_id: cand.post_id, name: ::DiscourseRUMXUTM::TranslationFreshness.field_name("de")).delete_all
    cand.update_columns(post_version: cand.post_version - 1)
    stale_loc = PostLocalization.find(cand.id); stale_synthetic = true
  end
end
de_reader = User.joins(:user_option).where(locale: "de", active: true, admin: false)
  .where(user_options: { automatically_translate: true })
  .where("user_options.understood_languages IS NULL OR cardinality(user_options.understood_languages) = 0")
  .where.not(id: [stale_loc&.post&.user_id, fresh_loc&.post&.user_id].compact).order(last_seen_at: :desc).first
job = ::Jobs::RumxRefreshStaleLocalizations
if stale_loc && fresh_loc && de_reader
  sp, fp = stale_loc.post, fresh_loc.post
  puts "  stale (legacy, no digest#{stale_synthetic ? ', SYNTHESIZED in a transaction' : ''}): post #{sp.id} v#{sp.version} de@v#{stale_loc.post_version} (#{sp.user.username}); fresh: post #{fp.id} v#{fp.version} de@v#{fresh_loc.post_version} (#{fp.user.username}); DE reader: #{de_reader.username}"
  I18n.with_locale(:de) do
    reader = Guardian.new(de_reader)
    check.("core would show the STALE translation (proves the gap)", core_show.call(sp, reader) == true)
    check.("legacy stale (version behind): NOT shown", ::ContentLocalization.show_translated_post?(sp, reader) == false)
    json = PostSerializer.new(sp, scope: reader, root: false).as_json
    check.("serializer serves the ORIGINAL cooked for stale, is_localized=false", json[:cooked] == sp.cooked && json[:cooked] != stale_loc.cooked && json[:is_localized] == false)
    check.("legacy fresh (version equal, no digest): shown", ::ContentLocalization.show_translated_post?(fp, reader) == true)
    check.("serializer serves the TRANSLATION for fresh", PostSerializer.new(fp, scope: reader, root: false).as_json[:cooked] == fresh_loc.cooked)
    check.("author sees the translation too (no author exemption — core behaviour kept)", ::ContentLocalization.show_translated_post?(fp, Guardian.new(fp.user)) == true)
    check.("anonymous DE reader: stale hidden, fresh shown", ::ContentLocalization.show_translated_post?(sp, Guardian.new) == false && ::ContentLocalization.show_translated_post?(fp, Guardian.new) == true)
  end
  I18n.with_locale(:en) do
    check.("EN reader of an EN post: unchanged (no translation, in_user_locale)", ::ContentLocalization.show_translated_post?(fp, Guardian.new(de_reader)) == false)
  end

  # ---- real jobs with a STUBBED translator (no LLM calls), inside a rolled-back transaction ----
  ::DiscourseAi::Translation::PostRawTranslator.class_eval do
    def translate
      return "[stub short]" if $rumx_stub_short
      "[stub #{@target_locale}] #{@text}"
    end
  end
  audit_before = AiApiAuditLog.count
  fp_id = fp.id
  digest_rows_before = PostCustomField.where(post_id: fp_id).where("name LIKE 'rumx_localized_src_md5_%'").count
  loc_rows_before = PostLocalization.where(post_id: fp_id).count
  redis_keys = %w[de fr en].flat_map { |l| ["post_relocalized_#{fp_id}_#{l}", tf.lock_key(fp, l)] }
  redis_keys.each { |k| Discourse.redis.del(k) }
  I18n.with_locale(:de) do
    reader = Guardian.new(de_reader)
    ActiveRecord::Base.transaction do
      post = Post.find(fp_id)
      # T0: a real localize() run records translation + digest under the lock
      loc = ::DiscourseAi::Translation::PostLocalizer.localize(post, "de")
      loc_updated_t0 = loc.reload.updated_at
      check.("T0 localize(): translation written from the stub and digest == md5(raw)", loc.raw.start_with?("[stub de]") && tf.digest_state(post, "de") == true && tf.fresh?(post, loc))
      check.("T0 lock released after localize()", Discourse.redis.get(tf.lock_key(post, "de")).nil?)
      check.("T0 digest recorded as ONE custom field row", PostCustomField.where(post_id: post.id, name: tf.field_name("de")).count == 1)
      # T1: the REAL on-edit job — de is fresh (digest) -> skipped without quota; fr without digest -> translated
      PostCustomField.where(post_id: post.id, name: tf.field_name("fr")).delete_all
      post = Post.find(fp_id)
      ::Jobs::DetectTranslatePost.new.execute(post_id: post.id)
      post = Post.find(fp_id)
      fr = post.localizations.find_by(locale: "fr")
      check.("T1 DetectTranslatePost: fresh de localization NOT re-translated (dedupe), no quota spent", loc.reload.updated_at == loc_updated_t0 && Discourse.redis.get("post_relocalized_#{fp_id}_de").nil?)
      check.("T1 DetectTranslatePost: fr (no digest) translated through core path and digest recorded", fr && fr.raw.start_with?("[stub fr]") && tf.digest_state(post, "fr") == true)
      # T2: GRACE-PERIOD EDIT — raw changes, version does not
      v = post.version
      post.update_columns(raw: post.raw + "\n* 5cl: Rumurmel")
      post = Post.find(fp_id)
      check.("T2 same version, changed raw -> both translations stale and hidden", post.version == v && tf.fresh?(post, post.localizations.find_by(locale: "de")) == false && ::ContentLocalization.show_translated_post?(post, reader) == false)
      check.("T2 serializer serves the ORIGINAL for the grace-edited post", PostSerializer.new(post, scope: reader, root: false).as_json[:cooked] == post.cooked)
      # T3: the REAL reconciler — exact SQL predicate finds them, refreshes, digests match again
      post.update_columns(updated_at: 10.minutes.ago)
      ids = job.stale_localization_ids(limit: 100, post_ids: [fp_id])
      check.("T3 SQL predicate finds exactly the 2 stale localizations of the post", ids.sort == post.localizations.pluck(:id).sort, ids.inspect)
      result = job.new.execute(post_ids: [fp_id])
      post = Post.find(fp_id)
      check.("T3 reconciler re-translated both (2 attempts, 2 refreshed)", result[:attempts] == 2 && result[:refreshed].size == 2, result.inspect)
      check.("T3 after reconcile: translations carry the new text, fresh, shown again", post.localizations.all? { |l| l.raw.include?("Rumurmel") && tf.fresh?(post, l) } && ::ContentLocalization.show_translated_post?(post, reader) == true)
      check.("T3 SQL predicate now finds nothing for the post", job.stale_localization_ids(limit: 100, post_ids: [fp_id]).empty?)
      # T4: duplicate custom-field rows (a past race) are tolerated and cleaned
      PostCustomField.create!(post_id: post.id, name: tf.field_name("de"), value: "garbage")
      post = Post.find(fp_id)
      check.("T4 duplicate digest row: oldest wins, still fresh", tf.digest_state(post, "de") == true)
      tf.record!(post, "de", tf.digest(post.raw))
      check.("T4 record! removes the duplicate", PostCustomField.where(post_id: post.id, name: tf.field_name("de")).count == 1)
      # T5: preload safety — a proxy without our field must not raise
      Post.preload_custom_fields([post], ["some_other_plugin_field"])
      state = begin; tf.digest_state(post, "de"); rescue => e; "RAISED #{e.class}"; end
      check.("T5 preloaded proxy without our field -> nil (version fallback), no NotPreloadedError", state.nil?)
      # T6: implausibly short translation is discarded, digest kept, nothing retries
      post = Post.find(fp_id)
      long_raw = post.raw + ("\nLorem ipsum dolor sit amet, consectetur adipiscing elit. " * 8)
      post.update_columns(raw: long_raw)
      post = Post.find(fp_id)
      $rumx_stub_short = true
      r6 = ::DiscourseAi::Translation::PostLocalizer.localize(post, "fr")
      $rumx_stub_short = false
      check.("T6 short translation (< 50% of a > 300-char source) -> discarded, localize returns nil", r6.nil? && post.localizations.reload.find_by(locale: "fr").nil?)
      check.("T6 digest still recorded -> dedupe blocks retries, SQL predicate finds nothing for fr", tf.digest_state(post, "fr") == true && ::DiscourseAi::Translation::PostLocalizer.has_relocalize_quota?(post, "fr") == false && job.stale_localization_ids(limit: 100, post_ids: [fp_id]).none? { |id| PostLocalization.find(id).locale == "fr" })
      $rumx_stub_short = false
      r6b = ::DiscourseAi::Translation::PostLocalizer.localize(post, "fr")
      check.("T6 normal-length translation of the same source is accepted", r6b && r6b.raw.start_with?("[stub fr]") && tf.fresh?(post, r6b))
      # T7: a localization in the post's own language is never a reconciler candidate
      own = PostLocalization.create!(post_id: post.id, locale: post.locale, raw: "x", cooked: "<p>x</p>", post_version: 0, localizer_user_id: -1)
      check.("T7 same-locale localization (version behind) excluded from the stale query", !job.stale_localization_ids(limit: 100, post_ids: [fp_id]).include?(own.id))
      raise ActiveRecord::Rollback
    end
  end
  redis_keys.each { |k| Discourse.redis.del(k) }
  check.("no LLM calls were made by the stubbed runs", AiApiAuditLog.count == audit_before, "before=#{audit_before} after=#{AiApiAuditLog.count}")
  check.("transaction rolled back (fixture post, digest rows, localizations unchanged)", Post.find(fp_id).raw == fp.raw && PostCustomField.where(post_id: fp_id).where("name LIKE 'rumx_localized_src_md5_%'").count == digest_rows_before && PostLocalization.where(post_id: fp_id).count == loc_rows_before)
  if stale_synthetic
    ActiveRecord::Base.connection.rollback_transaction
    check.("synthetic stale fixture rolled back", PostLocalization.find(stale_loc.id).post_version == stale_loc.post.version)
  end

  # ---- exactness / no starvation: SQL result == Ruby scan (eligible, quiet) ----
  sql_ids = job.stale_localization_ids(limit: 100_000)
  ruby_ids = PostLocalization.joins(post: :topic).where("posts.deleted_at IS NULL AND topics.deleted_at IS NULL AND posts.raw <> '' AND posts.user_id > 0 AND topics.archetype <> 'private_message'")
    .where("posts.updated_at < ?", job::QUIET_PERIOD.ago).includes(:post)
    .reject { |l| l.locale.to_s.split("_").first == l.post.locale.to_s.split("_").first } # same-language rows: PostLocalizer returns nil, never a candidate
    .reject { |l| tf.fresh?(l.post, l) }.map(&:id)
  check.("SQL staleness predicate == Ruby fresh?() over all localizations (exact, no starvation)", sql_ids.sort == ruby_ids.sort, "sql=#{sql_ids.size} ruby=#{ruby_ids.size}")
else
  check.("fixtures for translation checks found (stale de, fresh de, DE reader)", false, "stale=#{stale_loc&.id.inspect} fresh=#{fresh_loc&.id.inspect} reader=#{de_reader&.id.inspect}")
end

# ---------- 5b. Locale detection: quota cap + fallback ----------
puts
puts "-- locale detection safety net --"
pld = ::DiscourseAi::Translation::PostLocaleDetector
check.("PostLocaleDetector prepended", pld.singleton_class.ancestors.include?(::DiscourseRUMXUTM::PostLocaleDetectorExtension))
probe = Post.where.not(locale: nil).order(id: :desc).first
det_key = ::DiscourseAi::Translation::PostLocalizer.relocalize_key(probe, "")
Discourse.redis.del(det_key)
check.("detection quota: fresh -> allowed", ::DiscourseAi::Translation::PostLocalizer.has_relocalize_quota?(probe, "", skip_incr: true) == true)
Discourse.redis.set(det_key, 2, ex: 60)
check.("detection quota: capped at 2 even though MAX_QUOTA_PER_DAY is 20",
       ::DiscourseAi::Translation::PostLocalizer.has_relocalize_quota?(probe, "", skip_incr: true) == false &&
       ::DiscourseAi::Translation::LocalizableQuota::MAX_QUOTA_PER_DAY == 20)
Discourse.redis.del(det_key)
check.("translation quota still uses the raised cap (19 used -> allowed)", begin
  k = ::DiscourseAi::Translation::PostLocalizer.relocalize_key(probe, "zz"); Discourse.redis.set(k, 19, ex: 60)
  r = ::DiscourseAi::Translation::PostLocalizer.has_relocalize_quota?(probe, "zz", skip_incr: true); Discourse.redis.del(k); r == true
end)
# fallback: stub the detector to always fail, inside a rolled-back transaction
ActiveRecord::Base.transaction do
  target = Post.where(deleted_at: nil).where.not(topic_id: nil).order(id: :desc).first
  original_locale = target.locale
  target.update_columns(locale: nil)
  fail_key = "rumx_locale_detect_fail_#{target.id}"
  Discourse.redis.del(fail_key)
  ::DiscourseAi::Translation::LanguageDetector.class_eval { def detect; nil; end }
  first = pld.detect_locale(Post.find(target.id))
  check.("1st failed detection -> still nil (post keeps its place, core behaviour)", first.nil? && Post.find(target.id).locale.nil?)
  second = pld.detect_locale(Post.find(target.id))
  expected = target.topic&.locale.presence || SiteSetting.default_locale.to_s
  check.("2nd failed detection -> locale pinned to #{expected.inspect}, post leaves the queue",
         second == expected && Post.find(target.id).locale == expected)
  check.("pinned post is no longer a detection candidate",
         !::DiscourseAi::Translation::PostCandidates.send(:get).where(locale: nil).where(id: target.id).exists?)
  Discourse.redis.del(fail_key)
  target.update_columns(locale: original_locale)
  raise ActiveRecord::Rollback
end

# ---------- 6. Discourse AI re-translation quota ----------
puts
puts "-- re-translation quota --"
if defined?(::DiscourseAi::Translation::LocalizableQuota)
  q = ::DiscourseAi::Translation::LocalizableQuota::MAX_QUOTA_PER_DAY
  check.("MAX_QUOTA_PER_DAY raised to 20", q == 20, q.inspect)
  probe = Post.order(id: :desc).first
  key = ::DiscourseAi::Translation::PostLocalizer.relocalize_key(probe, "zz")
  Discourse.redis.del(key)
  check.("quota: fresh key -> allowed (no increment)", ::DiscourseAi::Translation::PostLocalizer.has_relocalize_quota?(probe, "zz", skip_incr: true) == true)
  Discourse.redis.set(key, 19, ex: 60)
  check.("quota: 19 used -> still allowed", ::DiscourseAi::Translation::PostLocalizer.has_relocalize_quota?(probe, "zz", skip_incr: true) == true)
  Discourse.redis.set(key, 20, ex: 60)
  check.("quota: 20 used -> blocked", ::DiscourseAi::Translation::PostLocalizer.has_relocalize_quota?(probe, "zz", skip_incr: true) == false)
  Discourse.redis.del(key)
else
  puts "  (discourse-ai not loaded — quota override skipped)"
end

# ---------- 7. noindex flags (2.5.0) ----------
puts
puts "-- noindex flags --"
ni = ::DiscourseRUMXUTM::Noindex
ns = ::DiscourseRUMXUTM::NoindexServing
live_actions = ListController.action_methods.select { |a| a.start_with?("category_") } - ["category_feed"]
missing = live_actions - ns::CATEGORY_LIST_ACTIONS
unknown = ns::CATEGORY_LIST_ACTIONS - ListController.action_methods.to_a
check.("CATEGORY_LIST_ACTIONS covers every live ListController category_* action (except feed)", missing.empty?, missing.inspect)
check.("CATEGORY_LIST_ACTIONS names only existing actions", unknown.empty?, unknown.inspect)
plugin_file = File.basename(plugin_path)
has_cb = ->(klass) { klass._process_action_callbacks.any? { |cb| cb.kind == :after && cb.filter.is_a?(Proc) && cb.filter.source_location&.first.to_s.end_with?(plugin_file) } }
check.("TopicsController has the plugin after_action", has_cb.(TopicsController))
check.("ListController has the plugin after_action", has_cb.(ListController))
check.("Sitemap#sitemap_topics still exists and is private", Sitemap.private_instance_methods.include?(:sitemap_topics))
check.("SitemapExtension prepended", Sitemap.ancestors.include?(::DiscourseRUMXUTM::SitemapExtension))

resp = ActionDispatch::Response.new
ns.add_noindex!(resp)
check.("header: fresh -> noindex", resp.headers["X-Robots-Tag"] == "noindex", resp.headers["X-Robots-Tag"].inspect)
ns.add_noindex!(resp)
check.("header: idempotent", resp.headers["X-Robots-Tag"] == "noindex")
resp2 = ActionDispatch::Response.new
resp2.headers["X-Robots-Tag"] = "nofollow, nosnippet"
ns.add_noindex!(resp2)
check.("header: merges into existing directives", resp2.headers["X-Robots-Tag"] == "nofollow, nosnippet, noindex", resp2.headers["X-Robots-Tag"])

cfg = ni.settings
now = Time.zone.now
Row = Struct.new(:topic_id, :about_topic, :words, :last_activity, :views90, :guarded, :flagged)
dec = ->(*a, exempt: []) { ni.decide(Row.new(*a), cfg, exempt.to_set, now) }
d = dec.(1, true, 5, now - 3.years, 0, true, false)
check.("guard beats about", d.flag == false && d.reason == "about" && d.guarded)
check.("thin: <100 words & >180 d -> flag", (d = dec.(2, false, 50, now - 200.days, 100, false, false)).flag && d.reason == "thin")
check.("thin needs age (100 d -> no flag)", !dec.(3, false, 50, now - 100.days, 0, false, false).flag)
check.("stale: >2 y & 4 views -> flag", (d = dec.(4, false, 5000, now - 3.years, 4, false, false)).flag && d.reason == "stale")
check.("stale: 10 views, not flagged -> no flag", !dec.(5, false, 5000, now - 3.years, 10, false, false).flag)
check.("hysteresis: 10 views, already flagged -> stays flagged", dec.(6, false, 5000, now - 3.years, 10, false, true).flag)
check.("hysteresis: 25 views, already flagged -> unflag", !dec.(7, false, 5000, now - 3.years, 25, false, true).flag)
check.("exempt beats thin", (d = dec.(8, false, 50, now - 3.years, 0, false, false, exempt: [8])).flag == false && d.exempt)
check.("active topic -> no reason, no flag", (d = dec.(9, false, 5000, now - 1.day, 1000, false, false)).flag == false && d.reason.nil?)
check.("nil last_activity counts as infinitely old", dec.(10, false, 50, nil, 0, false, false).flag)

t0 = Time.now
all = ni.decisions(cfg, now: now)
elapsed = (Time.now - t0).round(1)
sm = ni.summarize(all)
check.("decisions() over all public topics (#{all.size}) in #{elapsed}s", all.size > 100 && elapsed < 180)
puts "  summary: #{sm.inspect}"
fresh, freshness = ni.data_fresh?
check.("source data fresh (topic_view_stats, incoming_links)", fresh, freshness.inspect)

ActiveRecord::Base.transaction do
  probe = Topic.joins(:category).where(archetype: "regular", deleted_at: nil, visible: true).where(categories: { read_restricted: false }).order(:id).first
  TopicCustomField.where(topic_id: probe.id, name: ni::FIELD).delete_all
  TopicCustomField.create!(topic_id: probe.id, name: ni::FIELD, value: "t")
  reloaded = Topic.find(probe.id)
  check.("flagged? reads the typed boolean custom field", ni.flagged?(reloaded) == true)

  build_ctl = ->(ivar, obj, path) {
    c = Object.new
    c.instance_variable_set(ivar, obj)
    req = ActionDispatch::Request.new(Rack::MockRequest.env_for(path))
    rs = ActionDispatch::Response.new
    c.define_singleton_method(:request) { req }
    c.define_singleton_method(:response) { rs }
    c
  }
  ns.define_singleton_method(:enabled?) { true }
  c = build_ctl.(:@topic_view, Struct.new(:topic).new(reloaded), "/t/x/#{reloaded.id}")
  ns.apply_topic!(c)
  check.("apply_topic!: enabled + flagged -> X-Robots-Tag noindex", c.response.headers["X-Robots-Tag"] == "noindex", c.response.headers["X-Robots-Tag"].inspect)
  other = Topic.where(archetype: "regular", deleted_at: nil).where.not(id: reloaded.id).order(:id).first
  c = build_ctl.(:@topic_view, Struct.new(:topic).new(other), "/t/y/#{other.id}")
  ns.apply_topic!(c)
  check.("apply_topic!: unflagged topic -> no header", c.response.headers["X-Robots-Tag"].nil?)
  cat = Category.where(read_restricted: false).order(:id).first
  ns.define_singleton_method(:category_ids) { [cat.id] }
  c = build_ctl.(:@category, cat, "/c/#{cat.slug}/#{cat.id}")
  ns.apply_category!(c)
  check.("apply_category!: listed category -> header", c.response.headers["X-Robots-Tag"] == "noindex")
  other_cat = Category.where(read_restricted: false).where.not(id: cat.id).order(:id).first
  c = build_ctl.(:@category, other_cat, "/c/#{other_cat.slug}/#{other_cat.id}")
  ns.apply_category!(c)
  check.("apply_category!: other category -> no header", c.response.headers["X-Robots-Tag"].nil?)
  ns.define_singleton_method(:enabled?) { false }
  c = build_ctl.(:@topic_view, Struct.new(:topic).new(reloaded), "/t/x/#{reloaded.id}")
  ns.apply_topic!(c)
  check.("apply_topic!: disabled -> no header even when flagged", c.response.headers["X-Robots-Tag"].nil?)
  ns.singleton_class.send(:remove_method, :enabled?)
  ns.singleton_class.send(:remove_method, :category_ids)

  smap = Sitemap.find_by(name: "1") || Sitemap.new(name: "1")
  had_setting = SiteSetting.singleton_methods.include?(:rumx_noindex_enabled)
  SiteSetting.define_singleton_method(:rumx_noindex_enabled) { false }
  unfiltered = smap.send(:sitemap_topics).pluck(:id)
  SiteSetting.define_singleton_method(:rumx_noindex_enabled) { true }
  filtered = smap.send(:sitemap_topics).pluck(:id)
  SiteSetting.singleton_class.send(:remove_method, :rumx_noindex_enabled)
  SiteSetting.define_singleton_method(:rumx_noindex_enabled) { false } unless had_setting || SiteSetting.respond_to?(:rumx_noindex_enabled)
  check.("sitemap: filtered set == unfiltered − flagged ids (#{unfiltered.size} -> #{filtered.size})",
         unfiltered.include?(reloaded.id) && filtered.sort == (unfiltered - [reloaded.id]).sort)
  raise ActiveRecord::Rollback
end

puts
puts(fails.zero? ? "ALL CHECKS PASSED" : "#{fails} CHECK(S) FAILED")
exit(fails.zero? ? 0 : 1)
