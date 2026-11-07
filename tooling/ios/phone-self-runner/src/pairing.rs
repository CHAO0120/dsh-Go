//! Private pairing input shared by CoreDevice and XCTest. Never formatted or
//! included in an ABI event. This module performs no pairing setup or repair.
use std::path::Path;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use idevice::remote_pairing::RpPairingFile;
use serde::Deserialize;
use tokio::io::AsyncReadExt;
use zeroize::{Zeroize, Zeroizing};

use crate::{Failure, PAIRING};

pub(crate) const MAX_PAIRING: usize = 64 * 1024;
pub(crate) const MAX_PAIRING_BASE64: usize = 4 * MAX_PAIRING.div_ceil(3);

pub(crate) enum PairingInput {
    Memory(Zeroizing<Vec<u8>>),
    // Compatibility for the old XCTest ABI only. New Swift callers use Memory.
    LegacyFile(String),
}

impl PairingInput {
    pub(crate) fn parse(base64: Option<String>, file: Option<String>) -> Option<Self> {
        match (base64, file) {
            (Some(encoded), None) => {
                let encoded = Zeroizing::new(encoded);
                if encoded.is_empty() || encoded.len() > MAX_PAIRING_BASE64 {
                    return None;
                }
                let bytes = Zeroizing::new(STANDARD.decode(encoded.as_bytes()).ok()?);
                if bytes.len() > MAX_PAIRING
                    || Zeroizing::new(STANDARD.encode(bytes.as_slice())).as_str() != encoded.as_str()
                    || validate(&bytes).is_err()
                {
                    return None;
                }
                Some(Self::Memory(bytes))
            }
            (None, Some(file))
                if Path::new(&file).is_absolute()
                    && file.len() <= 4096
                    && !file.contains('\0') =>
            {
                Some(Self::LegacyFile(file))
            }
            _ => None,
        }
    }

    pub(crate) async fn load(&self) -> Result<RpPairingFile, Failure> {
        match self {
            Self::Memory(bytes) => validate(bytes),
            Self::LegacyFile(path) => {
                let file = tokio::fs::OpenOptions::new().read(true)
                    .custom_flags(libc::O_NONBLOCK).open(path).await.map_err(|_| PAIRING)?;
                let metadata = file.metadata().await.map_err(|_| PAIRING)?;
                if !metadata.is_file() || metadata.len() > MAX_PAIRING as u64 {
                    return Err(PAIRING);
                }
                let mut bytes = Zeroizing::new(Vec::new());
                file.take((MAX_PAIRING + 1) as u64)
                    .read_to_end(&mut bytes)
                    .await
                    .map_err(|_| PAIRING)?;
                validate(&bytes)
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PairingWire {
    public_key: plist::Data,
    private_key: plist::Data,
    identifier: String,
    alt_irk: Option<plist::Data>,
}
impl Drop for PairingWire {
    fn drop(&mut self) {
        self.private_key.as_mut().zeroize();
        self.public_key.as_mut().zeroize();
        self.identifier.zeroize();
        if let Some(irk) = &mut self.alt_irk { irk.as_mut().zeroize(); }
    }
}
fn validate(bytes: &[u8]) -> Result<RpPairingFile, Failure> {
    if bytes.is_empty() || bytes.len() > MAX_PAIRING {
        return Err(PAIRING);
    }
    // A typed flat record rejects duplicate keys and nested arrays/dictionaries
    // before building a recursive generic Value. The upstream parser alone
    // accepts unbounded identifiers and arbitrary alt_irk lengths.
    let value: PairingWire = plist::from_bytes(bytes).map_err(|_| PAIRING)?;
    if value.private_key.as_ref().len() != 32 || value.public_key.as_ref().len() != 32
        || value.identifier.is_empty() || value.identifier.len() > 128 || value.identifier.contains('\0') {
        return Err(PAIRING);
    }
    if value.alt_irk.as_ref().is_some_and(|value| value.as_ref().len() != 16) {
        return Err(PAIRING);
    }
    let record = RpPairingFile::from_bytes(bytes).map_err(|_| PAIRING)?;
    if record.e_private_key.verifying_key().to_bytes() != record.e_public_key.to_bytes() {
        return Err(PAIRING);
    }
    Ok(record)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes() -> Vec<u8> {
        RpPairingFile::generate("dsh-portable-test.invalid").to_bytes()
    }

    fn changed(field: &str, value: plist::Value) -> Vec<u8> {
        let mut dictionary: plist::Dictionary = plist::from_bytes(&bytes()).unwrap();
        dictionary.insert(field.into(), value);
        let mut result = Vec::new();
        plist::to_writer_binary(&mut result, &dictionary).unwrap();
        result
    }

    #[tokio::test]
    async fn memory_record_roundtrips_without_a_file() {
        let bytes = bytes();
        let input = PairingInput::parse(Some(STANDARD.encode(&bytes)), None).unwrap();
        let record = input.load().await.unwrap();
        assert_eq!(record.e_private_key.verifying_key(), record.e_public_key);
        assert!(PairingInput::parse(Some(STANDARD.encode(&bytes)), Some("/tmp/unused".into())).is_none());
    }

    #[test]
    fn malformed_or_inconsistent_pairing_is_rejected() {
        for (field, value) in [
            ("identifier", "".into()),
            ("identifier", "x".repeat(129).into()),
            ("identifier", "nul\0suffix".into()),
            ("alt_irk", plist::Value::Data(vec![0; 15])),
            ("alt_irk", plist::Value::Data(vec![0; 17])),
            ("private_key", plist::Value::Data(vec![0; 31])),
            ("private_key", plist::Value::Data(vec![1; 32])),
            ("HostID", "not-a-remote-pairing-record".into()),
        ] {
            assert!(PairingInput::parse(Some(STANDARD.encode(changed(field, value))), None).is_none(), "{field}");
        }
        assert!(validate(&vec![0; MAX_PAIRING + 1]).is_err());
        assert!(PairingInput::parse(Some("A".repeat(MAX_PAIRING_BASE64 + 1)), None).is_none());
        let encoded = STANDARD.encode(bytes());
        assert!(PairingInput::parse(Some(encoded + "\n"), None).is_none());
        assert!(PairingInput::parse(None, Some("relative.plist".into())).is_none());
        assert!(PairingInput::parse(None, None).is_none());
    }

    #[test]
    fn duplicate_and_deeply_nested_plist_fields_are_rejected_before_generic_parse() {
        let value: plist::Value = plist::from_bytes(&bytes()).unwrap();
        let mut xml = Vec::new(); plist::to_writer_xml(&mut xml, &value).unwrap();
        let xml = String::from_utf8(xml).unwrap();
        let duplicate = xml.replace("</dict>", "<key>identifier</key><string>duplicate</string></dict>");
        assert!(validate(duplicate.as_bytes()).is_err());
        let nested = format!("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>private_key</key>{}<data></data>{}</dict></plist>",
            "<array>".repeat(4000), "</array>".repeat(4000));
        assert!(nested.len() < MAX_PAIRING);
        assert!(validate(nested.as_bytes()).is_err());
    }
}
