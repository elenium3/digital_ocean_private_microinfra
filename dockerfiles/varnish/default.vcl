vcl 4.1;

import std;

backend default {
    .host = "wp-app";
    .port = "80";
    .first_byte_timeout = 300s;
    .connect_timeout = 5s;
    .between_bytes_timeout = 2s;
}

# Normalize the Host header
sub vcl_recv {
    if (req.http.host) {
        set req.http.Host = req.http.host;
    }

    # Do not cache admin pages
    if (req.url ~ "/(wp-admin/|wp-login.php)") {
        return (pass);
    }
}

sub vcl_backend_response {
    # Cache images, CSS, JS, fonts
    if (bereq.url ~ "\.(css|js|png|gif|jpg|jpeg|woff2?|eot|ttf|otf)(\?.*|)$") {
        unset beresp.http.set-cookie;
        set beresp.ttl = 1y;
    }

    # Cache WordPress-specific files
    if (bereq.url ~ "/(wp-includes/|wp-content/themes/|wp-content/plugins/|wp-content/uploads/)") {
        unset beresp.http.set-cookie;
        set beresp.ttl = 1h;
    }

    # Do not cache XML-RPC requests
    if (bereq.url ~ "^/xmlrpc.php$") {
        return (pass);
    }
}

sub vcl_deliver {
    # Remove Varnish-specific headers
    unset resp.http.Via;
    unset resp.http.X-Varnish;
    unset resp.http.X-Varnish-Cache;
    unset resp.http.X-Varnish-TTL;
}
