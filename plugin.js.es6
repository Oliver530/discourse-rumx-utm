// name: discourse-rumx-utm
// about: Add "rumx" UTM parameters to all outgoing links
// version: 1.0.0
// authors: Oliver Gerhardt

(function() {
    // Helper function to determine if a link is external.
    function isExternal(url) {
      try {
        // Create a URL object for the link.
        const linkUrl = new URL(url, window.location.origin);
        // Return true if the host of the link is different from our current host.
        return linkUrl.host !== window.location.host;
      } catch (e) {
        // If URL parsing fails, assume it's not external.
        return false;
      }
    }
  
    // Function to add UTM parameters to a URL.
    function addUTMParams(url) {
      try {
        const parsedUrl = new URL(url, window.location.origin);
        // Set UTM parameters
        parsedUrl.searchParams.set("utm_source", "rumx");
        parsedUrl.searchParams.set("utm_medium", "referral");
        parsedUrl.searchParams.set("utm_campaign", "rumx-forum");
        return parsedUrl.toString();
      } catch (e) {
        // If there's an error, return the original URL.
        return url;
      }
    }
  
    // Hook into Discourse's cooked post processing.
    // This event is triggered after the post HTML is generated.
    Discourse.hooks.on('post-process-cooked', ($cooked) => {
      // Find all anchor tags in the cooked post.
      $cooked.find('a').each(function() {
        const $link = $(this);
        const href = $link.attr('href');
        if (href && isExternal(href)) {
          const newUrl = addUTMParams(href);
          $link.attr('href', newUrl);
        }
      });
    });
  })();