# discourse-rumx-utm

Discourse plugin for community.rumx.com. One Ruby file, one JS initializer.

## What it does

1. **RX linkify (server-side, crawlable).** `RX7295` typed in a post becomes
   `<a href="https://rumx.com/en/rums/7295/">RX7295</a>` at cook time — for
   originals (`:post_process_cooked`) and for translated posts
   (`:post_process_localized_cooked`; content localization / Discourse AI
   translation cooks those separately and never fires the first event).
   Always the canonical `/en/` href, no slug, no UTM.
2. **Viewer-locale rewrite (client-side).** `rumx-rx-locale.js` points those
   anchors at `/de/` or `/fr/` when the header language switcher
   (`I18n.locale`) says so. HTML, e-mails, RSS, crawlers and the TopicLink
   rows keep `/en/`.
3. **Click counting survives the rewrite.** `TopicLinkClick.create_from`
   matches URL variants but never the path; `TopicLinkClickExtension`
   normalizes a clicked `/de|fr/rums/N/` back to `/en/` before the lookup
   (unless the post genuinely holds that exact link).
4. **UTM on author-typed external links** (`utm_source=rumx`,
   `utm_medium=referral`, `utm_campaign=rumx-forum`). rumx.com links that
   already carry UTM keep theirs (the Market Radar bot tags its own
   campaign); missing keys are filled, never replaced.
5. **AI translations stay fresh** (v2.2.0). Core shows a stored translation
   with no check that it still matches the post, Discourse AI re-translates at
   most twice a day per post and locale, and its backfill never refreshes an
   existing translation — on bottle-split posts DE/FR readers saw participant
   lists several versions old. Now:
   - every AI translation records an MD5 of the source raw it translated
     (`PostCustomField rumx_localized_src_md5_<locale>`); a translation is
     shown only while that digest equals the current raw — `post.version` is
     not enough, grace-period edits change raw without bumping it. Legacy
     translations without a digest fall back to the version comparison;
   - a stale translation is hidden (`ContentLocalization.show_translated_post?`
     prepend) and the reader gets the original;
   - `Jobs::RumxRefreshStaleLocalizations` (every 15 min) re-translates what
     the exact SQL predicate finds stale, at most 12 attempts per run, posts
     saved in the last 6 min left to the on-edit job; `post_ids:` narrows a
     run (`Jobs::RumxRefreshStaleLocalizations.new.execute(post_ids: [123])`);
   - re-translations of unchanged text are skipped before quota is spent
     (`has_relocalize_quota?` prepend), each translation runs under a
     per-post/locale `DistributedMutex`, and Discourse AI's
     `MAX_QUOTA_PER_DAY` is raised 2 → 20.
   Not covered: topic-list excerpts (topic localizations have no version) and
   e-mails, which core reads directly. Authors are not exempt from seeing the
   translation of their own post (core behaviour); one line in
   `ContentLocalizationExtension` would change that.

6. **Visible "translated" label** (v2.3.0). Core marks a translated post with
   a bare language icon whose tooltip is the only hint; readers did not notice
   they were reading translations and could not find "original". The
   `post-language-indicator` outlet is replaced by a label ("Übersetzt aus EN" /
   "Original (EN)", `config/locales/client.*.yml`); click/tap behaviour stays
   core's (desktop click toggles, mobile tap opens the tooltip with the
   "show original" button). Stylesheet `assets/stylesheets/common/`.

The three consumers of the clean RX href shape — the UTM pass (skip), the JS
rewrite and the click normalizer — key on the same regex. Change one, change
all three.

## Deploy

Merge to `master`, then **Admin → Upgrade** (`/admin/upgrade`) on the forum:
docker_manager pulls, precompiles assets, reloads the web server. No container
rebuild, no downtime.

Before deploying, validate the new `plugin.rb` against the live install —
`script/validate_live.rb` (usage in its header). It exercises both cook
handlers, idempotence on re-processing, the Market Radar case, the click
normalizer, and the translation-freshness path end to end with a STUBBED
translator (real `Jobs::DetectTranslatePost` and reconciler runs, no LLM
calls, everything inside a rolled-back transaction), plus an exactness check
of the SQL staleness predicate against a Ruby scan. Run it again after
Discourse core or discourse-ai upgrades: the plugin prepends core methods
(`TopicLinkClick.create_from`, `ContentLocalization.show_translated_post?`,
`DiscourseAi::Translation::PostLocalizer.localize` / `has_relocalize_quota?`)
and overrides a discourse-ai constant.

## After deploying 2.2.0

Nothing to run: the reconciler refreshes the existing stale translations on
its own (12 per 15 min). Check `Rails.logger` for
`discourse-rumx-utm: re-translated N stale localization(s)` or run
`Jobs::RumxRefreshStaleLocalizations.stale_localization_ids(limit: 100)` — it
should trend to empty.

## After deploying 2.1.0

Translated posts cooked before 2.1.0 have no RX links. Re-process them from
raw (the `recook: true` matters — without it the job starts from the stored
cooked HTML):

```ruby
# rails runner -e production
PostLocalization.pluck(:id).each { |id| Jobs.enqueue(:process_localized_cooked, post_localization_id: id, recook: true) }
```

Original posts need no rebake: the JS rewrite recognizes legacy anchors by
href shape plus anchor text.

## Verify in the browser

Switch the header language to DE, open a post with an RX code: the link must
point at `https://rumx.com/de/rums/<id>/` and keep its click badge. Click it
as a user who is not the post's author; `TopicLinkClick` for the `/en/`
TopicLink of that post must gain a row (24h rate limit per user/link — use a
fresh pair).
