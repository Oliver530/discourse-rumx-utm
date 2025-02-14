# name: discourse-rumx-utm
# about: Adds "rumx" UTM parameters to all outgoing external links in posts
# version: 1.0.0
# authors: Oliver Gerhardt
# url: https://github.com/Oliver530/discourse-rumx-utm

after_initialize do
    module ::DiscourseRUMXUTM
      class Engine < ::Rails::Engine
        engine_name "discourse_rumx_utm"
        isolate_namespace DiscourseRUMXUTM
      end
  
      # This processor will be applied to cooked posts.
      class UTMProcessor
        require 'uri'
        require 'rack/utils'
  
        def self.process(doc)
          # Iterate through each link in the cooked post.
          doc.css("a").each do |link|
            href = link.get_attribute("href")
            next if href.blank?
  
            if external_link?(href)
              new_href = add_utm_params(href)
              link.set_attribute("href", new_href)
            end
          end
        end
  
        # Determine if the link is external by comparing hosts.
        def self.external_link?(href)
          begin
            uri = URI.parse(href)
          rescue URI::InvalidURIError
            return false
          end
  
          # If the URI is relative or missing a host, consider it internal.
          return false if uri.host.blank?
  
          # Compare with the current site's host.
          begin
            current_host = URI.parse(Discourse.base_url).host
          rescue
            current_host = ""
          end
  
          uri.host != current_host
        end
  
        # Append UTM parameters to the URL.
        def self.add_utm_params(url)
          begin
            uri = URI.parse(url)
          rescue URI::InvalidURIError
            return url
          end
  
          # Parse existing query parameters.
          params = Rack::Utils.parse_nested_query(uri.query)
          # Add/override UTM parameters.
          params.merge!(
            "utm_source"   => "rumx",
            "utm_medium"   => "referral",
            "utm_campaign" => "rumx-forum"
          )
          # Build the updated query string.
          uri.query = Rack::Utils.build_nested_query(params)
          uri.to_s
        end
      end
    end
  
    # Hook into the cooked post processing step.
    on(:post_process_cooked) do |doc, post|
      ::DiscourseRUMXUTM::UTMProcessor.process(doc)
    end
  end