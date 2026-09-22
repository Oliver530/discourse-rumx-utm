# frozen_string_literal: true

# Login entry point for anonymous visitors on members-only content.
#
# Discourse answers an anonymous request for a topic or list page in a
# read_restricted category with a plain 404 (topics_controller.rb rescues
# InvalidAccess into NotFound without a permalink check; list_controller's
# set_category raises NotFound). Members who follow such a link while logged
# out (newsletter, an old bottle-split link, a category CTA on rumx.com) see
# "Page Not Found" instead of a login prompt.
#
# For an explicit allowlist of categories (site setting
# rumx_anon_login_redirect_category_ids, empty = feature off) this module
# changes the anonymous answer:
#   HTML / HEAD  -> core `redirect_to_login`: stores the original URL in the
#                   destination_url cookie (post number, ?page=, UTM kept),
#                   marks the response non-cacheable, 302 to /login. After
#                   login auth-complete.js returns to the original URL.
#   JSON / XHR   -> Discourse::InvalidAccess with our own message: core
#                   renders 403 with extras.html, the Ember exception page
#                   shows it, and the exception-wrapper connector adds a
#                   "Log in" button (the login route remembers the referrer).
# Everything else is untouched: logged-in users (with or without access),
# categories outside the allowlist (existence stays hidden: 404), deleted
# topics (core permalink path), PMs, other request methods.
#
# The decision is taken BEFORE `super`, from the real route params, so no
# rescued exception has to be interpreted. Cost: one primary-key lookup per
# anonymous topic/category request while the allowlist is non-empty.
module ::DiscourseRUMXUTM
  module AnonLoginRedirect
    MESSAGE_KEY = "rumx_anon_login_required"

    class << self
      def category_ids
        SiteSetting.rumx_anon_login_redirect_category_ids.to_s.split("|").map(&:to_i).reject(&:zero?)
      end

      def html_document?(request)
        !(request.format&.json? || request.xhr?)
      end

      # Executes the anonymous answer. Returns true when it responded/raised.
      def intercept!(controller)
        if html_document?(controller.request)
          controller.send(:redirect_to_login)
        else
          raise Discourse::InvalidAccess.new("login required", nil, custom_message: MESSAGE_KEY)
        end
        true
      end

      def candidate_request?(controller)
        return false if controller.current_user
        return false unless controller.request.get? || controller.request.head?
        category_ids.any?
      end
    end
  end

  module TopicsControllerAnonLoginRedirect
    def show(*args, **kwargs)
      if ::DiscourseRUMXUTM::AnonLoginRedirect.candidate_request?(self)
        raw_id = params[:topic_id].presence || params[:id]
        if raw_id.to_s.match?(/\A\d+\z/)
          topic = Topic.find_by(id: raw_id.to_i, deleted_at: nil, archetype: Archetype.default)
          if topic && ::DiscourseRUMXUTM::AnonLoginRedirect.category_ids.include?(topic.category_id) &&
               !guardian.can_see_topic?(topic)
            ::DiscourseRUMXUTM::AnonLoginRedirect.intercept!(self)
            return
          end
        end
      end
      super
    end
  end

  module ListControllerAnonLoginRedirect
    private

    def set_category
      if ::DiscourseRUMXUTM::AnonLoginRedirect.candidate_request?(self)
        category = Category.find_by_slug_path_with_id(params.require(:category_slug_path_with_id))
        if category && ::DiscourseRUMXUTM::AnonLoginRedirect.category_ids.include?(category.id) &&
             !guardian.can_see?(category)
          ::DiscourseRUMXUTM::AnonLoginRedirect.intercept!(self)
          return
        end
      end
      super
    end
  end
end
