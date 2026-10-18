//! Where Squircle may send a credential: the one origin policy for the CLI's
//! `--server` and the T3 URL it pairs with. HTTPS goes anywhere; plain HTTP
//! only to this Mac or a Tailscale address, whose traffic Tailscale already
//! encrypts. A server URL is an origin and nothing else, so userinfo, a
//! query, a fragment or a path are refused rather than silently dropped.

use anyhow::{Result, bail};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use url::{Host, Url};

/// `input` as `scheme://host[:port]` (no trailing slash), if credentials may
/// be sent there. `what` names the setting in errors, e.g. "--server".
pub fn credential_origin(input: &str, what: &str) -> Result<String> {
    let Ok(url) = Url::parse(input.trim()) else {
        bail!(
            "{what} {input:?} is not a URL; use an origin such as http://127.0.0.1:8787 or https://your-mac.your-tailnet.ts.net"
        );
    };
    if !matches!(url.scheme(), "http" | "https") {
        bail!("{what} must use http or https, not {}", url.scheme());
    }
    if !url.username().is_empty() || url.password().is_some() {
        bail!("{what} must not contain a user name or password; Squircle sends its own token");
    }
    if url.query().is_some() || url.fragment().is_some() || url.path() != "/" {
        let origin = url.origin().ascii_serialization();
        bail!("{what} must be just an origin with no path, query or fragment; use {origin}");
    }
    let Some(host) = url.host() else {
        bail!("{what} has no host");
    };
    if url.scheme() == "http" && !loopback(&host) && !tailscale(&host) {
        let mut https = url.clone();
        let _ = https.set_scheme("https");
        let _ = https.set_port(None);
        bail!(
            "{what} would send a token unencrypted to {host}: plain http is allowed only for this Mac \
             (127.0.0.1, ::1, localhost) or a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48, *.ts.net). \
             Use https (e.g. {}) or the host's Tailscale address",
            https.origin().ascii_serialization()
        );
    }
    Ok(url.origin().ascii_serialization())
}

/// This Mac: 127.0.0.0/8, ::1 or `localhost`.
pub fn loopback(host: &Host<&str>) -> bool {
    match host {
        Host::Domain(name) => name.eq_ignore_ascii_case("localhost"),
        Host::Ipv4(ip) => ip.is_loopback(),
        Host::Ipv6(ip) => ip.is_loopback(),
    }
}

/// A Tailscale address: CGNAT 100.64.0.0/10, the tailnet ULA
/// fd7a:115c:a1e0::/48, or a MagicDNS name under `.ts.net`.
fn tailscale(host: &Host<&str>) -> bool {
    match host {
        Host::Domain(name) => {
            let name = name.to_ascii_lowercase();
            name.len() > ".ts.net".len() && name.ends_with(".ts.net")
        }
        Host::Ipv4(ip) => tailscale_ip(IpAddr::V4(*ip)),
        Host::Ipv6(ip) => tailscale_ip(IpAddr::V6(*ip)),
    }
}

fn tailscale_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => u32::from(ip) & 0xffc0_0000 == u32::from(Ipv4Addr::new(100, 64, 0, 0)),
        IpAddr::V6(ip) => {
            let prefix = Ipv6Addr::new(0xfd7a, 0x115c, 0xa1e0, 0, 0, 0, 0, 0);
            ip.segments()[..3] == prefix.segments()[..3]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::credential_origin;

    fn ok(input: &str) -> String {
        credential_origin(input, "--server").unwrap_or_else(|e| panic!("{input}: {e}"))
    }
    fn refused(input: &str) -> String {
        match credential_origin(input, "--server") {
            Ok(origin) => panic!("{input} accepted as {origin}"),
            Err(e) => e.to_string(),
        }
    }

    #[test]
    fn plain_http_only_to_this_mac_or_tailscale() {
        assert_eq!(ok("http://127.0.0.1:8787"), "http://127.0.0.1:8787");
        assert_eq!(ok("http://127.0.0.1:8787/"), "http://127.0.0.1:8787");
        assert_eq!(ok("http://127.8.9.10:3773"), "http://127.8.9.10:3773");
        assert_eq!(ok("http://[::1]:8787"), "http://[::1]:8787");
        assert_eq!(ok("http://LOCALHOST:8787"), "http://localhost:8787");
        assert_eq!(ok("http://100.64.0.1:8787"), "http://100.64.0.1:8787");
        assert_eq!(
            ok("http://100.127.255.254:8787"),
            "http://100.127.255.254:8787"
        );
        assert_eq!(
            ok("http://[fd7a:115c:a1e0::1]:8787"),
            "http://[fd7a:115c:a1e0::1]:8787"
        );
        assert_eq!(
            ok("http://mac.tail1234.ts.net:8787"),
            "http://mac.tail1234.ts.net:8787"
        );
        assert_eq!(ok("https://192.168.1.20:8443"), "https://192.168.1.20:8443");
        assert_eq!(ok("https://example.com"), "https://example.com");

        for lan in [
            "http://192.168.1.20:8787",
            "http://10.0.0.5:8787",
            "http://100.63.255.255:8787",
            "http://100.128.0.1:8787",
            "http://[fd7a:115c:a1e1::1]:8787",
            "http://[::ffff:127.0.0.1]:8787",
            "http://remote-mac:8787",
            "http://remote-mac.local:8787",
            "http://ts.net:8787",
            "http://evil.ts.net.example.com:8787",
            "http://localhost.example.com:8787",
        ] {
            assert!(refused(lan).contains("unencrypted"), "{lan}");
        }
    }

    #[test]
    fn hostile_forms_are_refused() {
        for input in [
            "http://user:pass@127.0.0.1:8787",
            "http://user@127.0.0.1:8787",
            "https://127.0.0.1@evil.example.com",
            "http://127.0.0.1:8787/api",
            "http://127.0.0.1:8787/?x=1",
            "http://127.0.0.1:8787?",
            "http://127.0.0.1:8787#frag",
            "ftp://127.0.0.1",
            "file:///etc/passwd",
            "127.0.0.1:8787",
            "not a url",
        ] {
            refused(input);
        }
        assert!(refused("http://user:pw@localhost:1").contains("user name"));
        assert!(refused("http://localhost:1/x").contains("use http://localhost:1"));
    }
}
