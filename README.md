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

The three consumers of the clean RX href shape — the UTM pass (skip), the JS
rewrite and the click normalizer — key on the same regex. Change one, change
all three.

## Deploy

Merge to `master`, then **Admin → Upgrade** (`/admin/upgrade`) on the forum:
docker_manager pulls, precompiles assets, reloads the web server. No container
rebuild, no downtime.

Before deploying, validate the new `plugin.rb` against the live install —
`script/validate_live.rb` (usage in its header). It exercises both cook
handlers, idempotence on re-processing, the Market Radar case and the click
normalizer, inside a rolled-back transaction. Run it again after Discourse
core upgrades: the click normalizer prepends a core model method.

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
