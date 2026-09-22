import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

// Adds a login button to the Ember error page when an anonymous visitor hit a
// members-only topic or category (server answered 403 via AnonLoginRedirect).
// The login route stores the previous URL as destination_url, so the member
// lands on the requested content after signing in.
export default class RumxLoginCta extends Component {
  @service currentUser;
  @service router;

  get show() {
    return !this.currentUser && this.args.outletArgs?.thrown?.status === 403;
  }

  @action
  login() {
    this.router.transitionTo("login");
  }

  <template>
    {{#if this.show}}
      <div class="rumx-login-cta">
        <p>{{i18n "rumx_anon_login.hint"}}</p>
        <DButton
          class="btn-primary rumx-login-cta__button"
          @icon="user"
          @label="rumx_anon_login.button"
          @action={{this.login}}
        />
      </div>
    {{/if}}
  </template>
}
