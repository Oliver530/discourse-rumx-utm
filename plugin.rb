# name: discourse-rumx-utm
# about: Linkifies RXID codes to rumx.com (server-side, crawlable) + adds UTM to external links
# version: 2.0.0
# authors: Oliver Gerhardt
# url: https://github.com/Oliver530/discourse-rumx-utm

after_initialize do
  module ::DiscourseRUMXUTM
    class Engine < ::Rails::Engine
      engine_name "discourse_rumx_utm"
      isolate_namespace DiscourseRUMXUTM
    end

    class UTMProcessor
      require 'uri'
      require 'rack/utils'

      # RX + 1-6 digits, no leading zero. Catalog range verified 1..26189 (max 5
      # digits, RX1-RX9 are real rums); {0,5} = 1-6 digits gives growth headroom.
      # Lookarounds, not \b: Ruby \b treats "_" as a word char and mishandles
      # URL/email punctuation. (?<![[:alnum:]_]) / (?![[:alnum:]_]) require the
      # match to be a standalone token, so "TRX900", "BRX12", "RX9883abc",
      # "_RX9883" do not match. Case-insensitive: users type rx / Rx / RX.
      RX_REGEX = /(?<![[:alnum:]_])RX([1-9][0-9]{0,5})(?![[:alnum:]_])/i

      # Never linkify inside these. <a> guards idempotency (no nested anchors on
      # rebake); code/pre/etc are verbatim; onebox/quote are not the author's own
      # text. Class checks use token matching, not substring.
      SKIP_ANCESTOR_TAGS    = %w[a code pre script style textarea kbd samp].freeze
      SKIP_ANCESTOR_CLASSES = %w[onebox quote].freeze

      # ---- Pass 1: UTM on existing/author-typed external links (runs FIRST) ----
      # Because linkify runs AFTER this, the RX links we generate below are NOT
      # seen here and stay clean (no UTM) — intentional, for machine readability.
      def self.process(doc)
        doc.css("a").each do |link|
          href = link.get_attribute("href")
          next if href.blank?
          link.set_attribute("href", add_utm_params(href)) if external_link?(href)
        end
      end

      # ---- Pass 2: RX codes -> clean rumx.com links (runs AFTER UTM) ----
      def self.linkify_rx_codes(doc)
        # Snapshot to an Array: do not mutate a live NodeSet while iterating.
        doc.xpath(".//text()").to_a.each do |text_node|
          text = text_node.text
          next unless text.match?(RX_REGEX)
          next if skip_text_node?(text_node)

          replacements = []
          last = 0
          text.to_enum(:scan, RX_REGEX).each do
            m = Regexp.last_match
            if m.begin(0) > last
              replacements << Nokogiri::XML::Text.new(text[last...m.begin(0)], text_node.document)
            end
            a = Nokogiri::XML::Node.new("a", text_node.document)
            a["href"] = "https://rumx.com/en/rums/#{m[1]}/" # stable ID-URL, no slug, no UTM
            a.content = m[0]                                # anchor = exactly as typed (auto-escaped)
            replacements << a
            last = m.end(0)
          end
          replacements << Nokogiri::XML::Text.new(text[last..], text_node.document) if last < text.length

          # Insert siblings before the original node, then drop it. Sibling-insert
          # adopts nodes into the existing parent/document (more version-robust
          # than building a separate DocumentFragment and replacing).
          replacements.each { |node| text_node.add_previous_sibling(node) }
          text_node.remove
        end
      end

      def self.skip_text_node?(node)
        node.ancestors.any? do |anc|
          next false unless anc.element?
          classes = anc["class"].to_s.split
          SKIP_ANCESTOR_TAGS.include?(anc.name.downcase) ||
            (SKIP_ANCESTOR_CLASSES & classes).any?
        end
      end

      def self.external_link?(href)
        begin
          uri = URI.parse(href)
        rescue URI::InvalidURIError
          return false
        end
        return false if uri.host.blank?
        begin
          current_host = URI.parse(Discourse.base_url).host
        rescue
          current_host = ""
        end
        uri.host != current_host
      end

      def self.add_utm_params(url)
        begin
          uri = URI.parse(url)
        rescue URI::InvalidURIError
          return url
        end
        params = Rack::Utils.parse_nested_query(uri.query)
        params.merge!(
          "utm_source"   => "rumx",
          "utm_medium"   => "referral",
          "utm_campaign" => "rumx-forum"
        )
        uri.query = Rack::Utils.build_nested_query(params)
        uri.to_s
      end
    end
  end

  # Order matters: UTM first (touches author-typed links), then RX-linkify
  # (creates clean, UTM-free identifier links).
  on(:post_process_cooked) do |doc, post|
    ::DiscourseRUMXUTM::UTMProcessor.process(doc)
    ::DiscourseRUMXUTM::UTMProcessor.linkify_rx_codes(doc)
  end
end
