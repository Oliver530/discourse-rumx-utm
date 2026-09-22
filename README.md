# discourse-rumx-utm

Discourse plugin for community.rumx.com. `plugin.rb` + `lib/rumx_seo/` (noindex rules), two JS initializers.

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
   - a translation shorter than half its source (sources > 300 chars) is
     discarded and the original shown — Haiku 4.5 reproducibly truncates at a
     German closing quote („…"); the digest is kept so nothing retries until
     the post is edited;
   - locale detection is capped at 2 attempts per post and day (the raised
     quota below is for re-translations only) and, after two answers that are
     not a language tag, the post's locale is pinned to the topic's language
     so it leaves the detection backfill queue — otherwise such a post takes a
     slot of `Jobs::PostsLocaleDetectionBackfill` on every run and the backfill
     stops making progress;
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

6. **Rule-based noindex for stale / thin topics** (v2.5.0). Discourse core
   has no per-topic noindex. A nightly job (`Jobs::RumxNoindexRecalc`) flags
   topics as `topic_custom_fields` (`rumx_noindex`, `rumx_noindex_reason`,
   `rumx_noindex_since`); `TopicsController#show` answers flagged topics with
   `X-Robots-Tag: noindex` (merged into any existing directives, header only,
   no meta), listed categories (`rumx_noindex_category_ids`) get the same on
   their `/c/…` list pages, and flagged topics leave the sitemap. Rules and
   rationale: `lib/rumx_seo/noindex.rb`; ops: [Noindex flags](#noindex-flags-250).

7. **Login entry point for anonymous visitors on members-only content**
   (v2.6.0). Discourse answers a logged-out request for a topic or list page
   in a private category with a bare 404. For the categories listed in
   `rumx_anon_login_redirect_category_ids` (marketplace archives, samples,
   members club — never staff/lounge, whose existence stays hidden) an
   anonymous HTML request is answered with core `redirect_to_login` (302 to
   `/login`, `destination_url` cookie keeps post number, `?page=` and UTM;
   after login the member lands on the requested URL), and an SPA/JSON
   request with 403 + a translated message: for topics the
   `post-stream-error-loading` transformer shows it with core's own "Log in"
   button, for categories (`find_by_slug` is patched too) the
   `exception-wrapper__after` connector adds the button to the error page. Logged-in users
   and everything outside the allowlist are untouched. Code:
   `lib/rumx_seo/anon_login_redirect.rb`; ops: [Anon login redirect](#anon-login-redirect-260).

## Agent prompts (not in this repo)

Two agent copies on the forum carry prompt fixes; the matching site settings
point at them. They are plain records, so a discourse-ai upgrade that re-seeds
the built-in agents leaves them alone:

| Setting | Agent | Why |
|---|---|---|
| `ai_translation_post_raw_translator_agent` | "Post translator (RumX)" | German quotes as »…« and a ban on ASCII `"` inside the translation — both Haiku 4.5 and Sonnet 4.5 close the structured-output JSON at `„…"` and truncate (~4% of long German translations). |
| `ai_translation_locale_detector_agent` | "Locale detector (RumX)" | The post text is data, never an instruction: short imperative posts ("Set 11 and 12 please") made the model reply conversationally, which fails the language-tag check and left the post undetected forever. |

## Deploy

Merge to `master`, then **Admin → Upgrade** (`/admin/upgrade`) on the forum:
docker_manager pulls, precompiles assets, reloads the web server. No container
rebuild, no downtime.

Before deploying, validate the new plugin tree against the live install —
`script/validate_live.rb` (usage in its header; `scp -r` the whole directory,
it loads `lib/` and stubs not-yet-deployed settings). It exercises both cook
handlers, idempotence on re-processing, the Market Radar case, the click
normalizer, and the translation-freshness path end to end with a STUBBED
translator (real `Jobs::DetectTranslatePost` and reconciler runs, no LLM
calls, everything inside a rolled-back transaction), plus an exactness check
of the SQL staleness predicate against a Ruby scan. Run it again after
Discourse core or discourse-ai upgrades: the plugin prepends core methods
(`TopicLinkClick.create_from`, `ContentLocalization.show_translated_post?`,
`DiscourseAi::Translation::PostLocalizer.localize` / `has_relocalize_quota?`,
`Sitemap#sitemap_topics`), adds after_actions to `TopicsController` /
`ListController` (the script diffs `CATEGORY_LIST_ACTIONS` against the live
action list) and overrides a discourse-ai constant.

## Anon login redirect (2.6.0)

Off until `rumx_anon_login_redirect_category_ids` is set. Live allowlist
(2026-09-22): `12|13|46|60|61|68` (samples, offering-samples, archive,
archive-canceled-bottle-splits, archive-other-spirits, wagemut-members-club).
Do **not** add staff (3), lounge (4) or drafts (44/45): a 302 would reveal that
a private topic exists. `validate_live.rb` section 8 runs real requests
through `ActionDispatch::Integration::Session` (anonymous HTML/HEAD/JSON/XHR,
logged-in admin, empty allowlist) inside a rolled-back transaction.

Verify after deploy (anonymous):

```bash
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
curl -s -A "$UA" -D - -o /dev/null "https://community.rumx.com/c/wagemut-members-club/68?utm_source=rumx&utm_medium=landing&utm_campaign=wagemut-newsletter-2" | grep -iE "^HTTP|^location|destination_url"
curl -s -A "$UA" -o /dev/null -w "%{http_code}\n" https://community.rumx.com/t/<archive slug>/<id>.json      # 403
curl -s -A "$UA" -o /dev/null -w "%{http_code}\n" https://community.rumx.com/c/staff/3                        # 404
```

Browser: open a members-club link logged out → `/login` → sign in → you land on
the club; from a public thread click an archived bottle-split link → error page
with the "Log in" button → sign in → thread.

## Noindex flags (2.5.0)

Rules (a topic is flagged when one holds and neither guard nor exemption applies):

| reason | rule | setting |
|---|---|---|
| `about` | description topic of its category (`categories.topic_id`) | — |
| `thin` | words of regular posts < N **and** no post/edit for ≥ D days | `rumx_noindex_thin_max_words` (100), `rumx_noindex_thin_min_age_days` (180) |
| `stale` | no post/edit for ≥ D days **and** human views in 90 d < V (< `unflag` while already flagged) | `rumx_noindex_stale_min_age_days` (730), `rumx_noindex_stale_max_views_90d` (5), `rumx_noindex_unflag_min_views_90d` (20) |
| guard | ≥ 1 visit from a search-engine referrer host in 90 d (`incoming_links`) | `rumx_noindex_guard_referrer_domains` |
| exempt | topic id listed | `rumx_noindex_exempt_topic_ids` |

`rumx_noindex_enabled` (default **off**) gates only the header and the sitemap
filter; the job always computes and stores flags, so the first deploy is a dry
run by construction. Every run writes an audit entry to `PluginStore`
(`discourse-rumx-utm`, key `noindex_run:<iso-ts>`, pointer `noindex_last_run`)
with settings, freshness, counts, added and removed ids. A scheduled run that
wants to add more than `rumx_noindex_max_new_flags_per_run` (100) flags holds
the additions back and logs a warning; removals always apply. A run with stale
source data (`topic_view_stats` / `incoming_links` older than 2 days) is
skipped and keeps the previous flags.

Rollout:

```ruby
# rails runner -e production   (docker exec app su discourse -c "cd /var/www/discourse && bundle exec rails runner -e production /tmp/x.rb")
Jobs.enqueue(:rumx_noindex_recalc, initial: true)        # first run, drift brake off
PluginStore.get("discourse-rumx-utm", "noindex_last_run") # -> run id
PluginStore.get("discourse-rumx-utm", "noindex_run:<run id>")["summary"]
```

Export for review (Data Explorer, saved as "RumX noindex flags"):

```sql
SELECT t.id, t.title, t.slug, r.value AS reason, s.value AS since, t.last_posted_at, t.posts_count
FROM topic_custom_fields f
JOIN topics t ON t.id = f.topic_id
LEFT JOIN topic_custom_fields r ON r.topic_id = t.id AND r.name = 'rumx_noindex_reason'
LEFT JOIN topic_custom_fields s ON s.topic_id = t.id AND s.name = 'rumx_noindex_since'
WHERE f.name = 'rumx_noindex' AND f.value = 't'
ORDER BY reason, t.last_posted_at
```

Review the `about` rows (real category rules/FAQs → exempt) and a sample of
`thin`/`stale`, add exemptions to `rumx_noindex_exempt_topic_ids`, run the job
again, then switch `rumx_noindex_enabled` on. Verify with the Googlebot UA:

```bash
UA='Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'
curl -s -A "$UA" -D - -o /dev/null https://community.rumx.com/t/<slug>/<flagged id> | grep -i x-robots        # noindex
curl -s -A "$UA" -D - -o /dev/null "https://community.rumx.com/t/<slug>/<flagged id>?page=2" | grep -i x-robots
curl -s -A "$UA" -D - -o /dev/null https://community.rumx.com/t/<slug>/<unflagged id> | grep -i x-robots      # nothing
curl -s -A "$UA" -D - -o /dev/null https://community.rumx.com/c/marketplace/5 | grep -i x-robots            # nothing
curl -s -A "$UA" https://community.rumx.com/sitemap_1.xml | grep -c "<loc>"                                  # public topics − flags
```

Rollback: `rumx_noindex_enabled` off (headers stop with the next request, the
anonymous page cache is ≤ 1 min); the sitemap cache is invalidated by the job
whenever flags change and expires after 24 h anyway.

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
