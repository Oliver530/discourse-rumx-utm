# frozen_string_literal: true

# name: discourse-rumx-utm
# about: Adds "rumx" UTM parameters to all outgoing links.
# version: 1.0.0
# authors: Oliver Gerhardt
# url: https://github.com/Oliver530/discourse-rumx-utm

enabled_site_setting :utm_rumx_enabled

after_initialize do
  # Hook into the cooked post processing
  on(:post_process_cooked) do |doc, post|
    # Only process if the plugin is enabled via Site Settings.
    next unless SiteSetting.utm_rumx_enabled

    # Determine the internal host from the Discourse base URL.
    begin
      internal_host = URI.parse(Discourse.base_url).host
    rescue StandardError
      internal_host = nil
    end

    # Find all anchor tags with an href attribute.
    doc.css("a[href]").each do |anchor|
      href = anchor["href"]
      begin
        uri = URI.parse(href)
      rescue URI::InvalidURIError
        # Skip if the URL cannot be parsed.
        next
      end

      # Only process absolute URLs (i.e. those with a scheme and host).
      next unless uri.scheme && uri.host

      # Skip internal links.
      if internal_host && uri.host.downcase == internal_host.downcase
        next
      end

      # Parse the current query string, if any.
      query_params = URI.decode_www_form(uri.query || "")

      # Append UTM parameters if they aren’t already present.
      query_params << ["utm_source", "rumx"]   unless query_params.any? { |k, _| k == "utm_source" }
      query_params << ["utm_medium", "rumx"]   unless query_params.any? { |k, _| k == "utm_medium" }
      query_params << ["utm_campaign", "rumx"] unless query_params.any? { |k, _| k == "utm_campaign" }

      # Set the updated query string.
      uri.query = URI.encode_www_form(query_params)
      anchor["href"] = uri.to_s
    end
  end
end