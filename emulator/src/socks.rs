//! The SOCKS5 proxy into the VPN (docs/vpn.md), as tests/emulate/network.py has it: a user name
//! and password, and CONNECT by name so the proxy resolves it on the far side.
use std::io::{Error, ErrorKind, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::settings;

pub struct Socks5 {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
}

impl Socks5 {
    /// GAME_SOCKS_USER, GAME_SOCKS_PASSWORD and GAME_SOCKS_ADDRESS (127.0.0.1:1080 if unset).
    pub fn from_settings() -> Result<Socks5, String> {
        let (Some(user), Some(password)) = (settings::setting("GAME_SOCKS_USER"), settings::setting("GAME_SOCKS_PASSWORD"))
        else {
            return Err("--vpn needs GAME_SOCKS_USER and GAME_SOCKS_PASSWORD in local.env".into());
        };
        let address = settings::setting("GAME_SOCKS_ADDRESS").unwrap_or_else(|| "127.0.0.1:1080".into());
        let (host, port) = match address.rsplit_once(':') {
            Some((host, port)) => {
                (host.to_string(), port.parse().map_err(|_| format!("GAME_SOCKS_ADDRESS has no port number: {address}"))?)
            }
            None => (address, 1080),
        };
        Ok(Socks5 { host, port, user, password })
    }

    /// A connection to name:port through the proxy, blocking, with timeout on reads and writes.
    pub fn open(&self, name: &str, port: u16, timeout: Duration) -> std::io::Result<TcpStream> {
        let proxy = (self.host.as_str(), self.port)
            .to_socket_addrs()?
            .next()
            .ok_or_else(|| Error::new(ErrorKind::NotFound, format!("no address for the proxy {}", self.host)))?;
        let mut s = TcpStream::connect_timeout(&proxy, timeout)?;
        s.set_read_timeout(Some(timeout))?;
        s.set_write_timeout(Some(timeout))?;
        s.set_nodelay(true)?;
        s.write_all(b"\x05\x01\x02")?; // version 5, one method: user/password
        let mut reply = [0u8; 2];
        s.read_exact(&mut reply)?;
        if reply != *b"\x05\x02" {
            return Err(Error::other("the proxy wants another method"));
        }
        let (user, password) = (self.user.as_bytes(), self.password.as_bytes());
        if user.len() > 255 || password.len() > 255 || name.len() > 255 {
            return Err(Error::new(ErrorKind::InvalidInput, "a SOCKS5 field is longer than 255 bytes"));
        }
        let mut auth = vec![1, user.len() as u8];
        auth.extend_from_slice(user);
        auth.push(password.len() as u8);
        auth.extend_from_slice(password);
        s.write_all(&auth)?;
        s.read_exact(&mut reply)?;
        if reply != *b"\x01\x00" {
            return Err(Error::new(ErrorKind::PermissionDenied, "the proxy refused the password"));
        }
        let mut request = vec![5, 1, 0, 3, name.len() as u8];
        request.extend_from_slice(name.as_bytes());
        request.extend_from_slice(&port.to_be_bytes());
        s.write_all(&request)?;
        let mut head = [0u8; 4];
        s.read_exact(&mut head)?;
        if head[1] != 0 {
            return Err(Error::new(
                ErrorKind::ConnectionRefused,
                format!("the proxy could not reach {name}:{port} (reply {:02x})", head[1]),
            ));
        }
        let rest = match head[3] {
            1 => 4,
            4 => 16,
            _ => {
                let mut size = [0u8; 1];
                s.read_exact(&mut size)?;
                size[0] as usize
            }
        };
        let mut bound = vec![0u8; rest + 2];
        s.read_exact(&mut bound)?;
        Ok(s)
    }
}

#[cfg(test)]
mod tests {
    use super::Socks5;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::time::Duration;

    /// A one-connection proxy that takes the password "right" and returns what the client sent.
    fn fake_proxy() -> (u16, std::thread::JoinHandle<Vec<u8>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut seen = Vec::new();
            let take = |s: &mut std::net::TcpStream, n: usize, seen: &mut Vec<u8>| {
                let mut buffer = vec![0u8; n];
                s.read_exact(&mut buffer).unwrap();
                seen.extend_from_slice(&buffer);
                buffer
            };
            take(&mut s, 3, &mut seen);
            s.write_all(b"\x05\x02").unwrap();
            let user_size = take(&mut s, 2, &mut seen)[1] as usize;
            take(&mut s, user_size, &mut seen);
            let password_size = take(&mut s, 1, &mut seen)[0] as usize;
            let password = take(&mut s, password_size, &mut seen);
            if password != b"right" {
                s.write_all(b"\x01\x01").unwrap();
                return seen;
            }
            s.write_all(b"\x01\x00").unwrap();
            let name_size = take(&mut s, 5, &mut seen)[4] as usize;
            take(&mut s, name_size + 2, &mut seen);
            s.write_all(b"\x05\x00\x00\x01\x0a\x00\x00\x01\x04\x38").unwrap();
            s.write_all(b"through").unwrap();
            seen
        });
        (port, server)
    }

    fn proxy(port: u16, password: &str) -> Socks5 {
        Socks5 { host: "127.0.0.1".into(), port, user: "joe".into(), password: password.into() }
    }

    #[test]
    fn connects_by_name_with_the_password() {
        let (port, server) = fake_proxy();
        let mut s = proxy(port, "right").open("example.org", 443, Duration::from_secs(5)).unwrap();
        let mut payload = [0u8; 7];
        s.read_exact(&mut payload).unwrap();
        assert_eq!(&payload, b"through");
        let mut expected = b"\x05\x01\x02\x01\x03joe\x05right\x05\x01\x00\x03\x0bexample.org".to_vec();
        expected.extend_from_slice(&443u16.to_be_bytes());
        assert_eq!(server.join().unwrap(), expected);
    }

    #[test]
    fn a_refused_password_is_an_error() {
        let (port, server) = fake_proxy();
        let error = proxy(port, "wrong").open("example.org", 443, Duration::from_secs(5)).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert_eq!(server.join().unwrap(), b"\x05\x01\x02\x01\x03joe\x05wrong");
    }
}
