//! Signing a service-account assertion.
//!
//! A service-account key is an RSA private key with an email beside it. Turning it into an
//! access token is one exchange: build a JWT that says who you are and what you want, sign it
//! RS256, and post it to the token endpoint as a
//! `urn:ietf:params:oauth:grant-type:jwt-bearer` assertion. This module does the first half —
//! the network half belongs to whoever has an HTTP capability, which in a provider package is
//! the guest.
//!
//! ## Why not a JWT crate
//!
//! Every one of them brings a validator, a clock and an algorithm registry, and none of that is
//! wanted here: this only ever SIGNS, with one algorithm, for one audience. What is left after
//! removing all of that is the sixty lines below.
//!
//! ## No clock
//!
//! `now_secs` is a parameter. A guest has no clock worth having, and a signature over a time
//! somebody else chose is the only version of this that can be tested.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64URL, Engine};
use rsa::pkcs1v15::Pkcs1v15Sign;
use rsa::pkcs8::DecodePrivateKey;
use rsa::RsaPrivateKey;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The parts of a service-account key file this needs.
///
/// Deserialised straight from the JSON the provider hands out, so a user pastes the file and
/// nothing has to be transcribed. Unknown fields are ignored: the file carries half a dozen
/// more, and rejecting a key because it gained one would be a failure with no visible cause.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceAccount {
    pub client_email: String,
    /// PEM, PKCS#8. This is the secret; it never leaves the package whose slot holds it.
    pub private_key: String,
    /// Where the assertion is posted. Taken from the file rather than hardcoded, because it is
    /// the audience the signature commits to — the two must agree or the exchange is refused.
    #[serde(default = "google_token_uri")]
    pub token_uri: String,
    #[serde(default)]
    pub project_id: Option<String>,
}

fn google_token_uri() -> String {
    "https://oauth2.googleapis.com/token".to_string()
}

/// How long an assertion may be presented for. An hour is the maximum Google accepts; the
/// token it buys expires on its own schedule, which is a different clock.
const ASSERTION_TTL_SECS: u64 = 3600;

/// Build a signed assertion for `scope`, valid from `now_secs`.
pub fn assertion(sa: &ServiceAccount, scope: &str, now_secs: u64) -> Result<String, String> {
    let key = RsaPrivateKey::from_pkcs8_pem(sa.private_key.trim())
        .map_err(|e| format!("the service-account key is not a usable PKCS#8 private key: {e}"))?;

    // `typ` is not required by the spec and every implementation sends it; leaving it out is
    // the kind of difference that gets a request refused with no explanation attached.
    let header = serde_json::json!({ "alg": "RS256", "typ": "JWT" });
    let claims = serde_json::json!({
        "iss":   sa.client_email,
        "scope": scope,
        "aud":   sa.token_uri,
        "iat":   now_secs,
        "exp":   now_secs + ASSERTION_TTL_SECS,
    });

    let signing_input = format!(
        "{}.{}",
        B64URL.encode(serde_json::to_vec(&header).map_err(|e| e.to_string())?),
        B64URL.encode(serde_json::to_vec(&claims).map_err(|e| e.to_string())?),
    );

    // Sign the DIGEST, not the message: PKCS#1 v1.5 wraps a hash together with the identifier
    // of the algorithm that produced it, and `Pkcs1v15Sign::new::<Sha256>()` is what supplies
    // that identifier.
    let digest = Sha256::digest(signing_input.as_bytes());
    let signature = key
        .sign(Pkcs1v15Sign::new::<Sha256>(), &digest)
        .map_err(|e| format!("signing the assertion failed: {e}"))?;

    Ok(format!("{signing_input}.{}", B64URL.encode(signature)))
}

/// The form body that exchanges an assertion for an access token.
///
/// Here rather than at the call site because the grant type is part of the protocol and not a
/// choice: a caller that wrote it out would be a caller that could write it wrong.
pub fn assertion_form(assertion: &str) -> String {
    format!(
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={assertion}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::pkcs1v15::VerifyingKey;
    use rsa::pkcs8::{DecodePublicKey, EncodePublicKey, LineEnding};
    use rsa::signature::Verifier;

    /// A throwaway 2048-bit key, generated for this file and used nowhere else.
    const TEST_KEY: &str = "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC2chgjvmTnUSlG\nzCOBOfVn8eTFCTHp4J7FizY8qjfc94U2WkNIsGDCUF5hRFK7UvwvCMMKneYCNZ1E\ndx+J9/4i5xSN5IICzVNFuTDm7j6icdyzrnP86Bc8fqHoGLyhVQEXhE+8TZyFVrwf\nyouNrd0V8kSKLAHoSeW3Q+EIzrLaEufHgCXl1TFCSy/VK37EBMmdhZzJFrXsmuj6\n7wYIVss589uRgaEgbV4pEcv7E09DLuOU/edr6FLyXrez6/j9TtXueYiT4yuPOuIc\n4CJbB0rEZVvMwF1yPFCRmCBB8OQFx6Yx/fpQ4vq0coTVakGvLb56IoNEFarJiODn\n54ZltOspAgMBAAECggEAAS2EjIswsryXpV/Gf+b8TQGRrkL0WfPrr89JrZkUt2i3\n/lqVUh1ktoRseONxxvNOx6KebbheES1q7ej4oLxOMp1Rc5FiKdCiWmd1vRvpzBnW\nPf5g5yT8F2rNh/Ehm0da9IhTt8hm0QaMZtvOIanvF4ftm4MUDRLtuHc9TJWsWmjf\nguUwBlr11wntCxWUCQCHjCaJCLGtNIWHrbl1ce0FDf1DJy7sG2ioTyoRf9OEC+P+\n//0DjIE0qNIB+EzHDQQ7ffePdZl5wrf4U3OPkikAtS3y8YesV+HFNRqEN3KyMI+b\nHbxq0rgdf2e8WrWu11RCPeAQImZlTyDQg63o5q2MgQKBgQD8AviZadVTn56ojbWp\nIv/icuhHLJ+J3GvsJKHOTrvCY0SQe/5rkCSNXbA1OlJuh4DU3jHr5vWkOEtbG/SC\n77T0dplC6ndq13zW5skVtbedd19AklOOZc5VWMdmOV41AC43hB6flOkj7j0cwoqq\nXwwzpN2774Voiaj96HsmJUVmaQKBgQC5VUaZ6+XuRpdNCKjxKXn00roQpPXlmkCD\nxIUVzzVKr6q4LtR3q44EFQXruthAI/r4FVUcouWS7YHdl6pnTYSYychQqICPvWbI\nwBEV/dxWaWsUoq47+vb6cObrxcOpkmeOpHk2C1RRl+4NMXU3mhedz+QCma0GYeLT\na62TRxJGwQKBgQDhR2Kl+aa6p1D0SiGffesSqjecEHbZjVJoeWKvg1By97w+EKmh\ny+vw91RicK1povX21F36DK9/ytcKLhZIyjGP60kcOW7g8prlnM8a+iOWvzRGC8hn\n3fgx8Tfm2NevN2cZN6EMdNhoxzqYMAw3Oto0fGe+7eHrTkvkFmOn+N9uKQKBgBGV\nf69W7GfhFrXeXnkTIFkULUcq/5GbQwe9e4sIL9w4MpBrEQmRo1XL0NX+0kmzoDot\ne/fNlM6N7kZh/27xseT1MCZG9nus0rW1U2msvl0Mf3ZjwPg75Xb5g09XYisSkvS7\nsixogsWDDrj9ukteOWNluBJvFjWG0AiTLNLOaXOBAoGBAKg0zyDr0VdZgFnRrna3\n8/pUKXQ4gg4QNKxK6ZvknHekhu1lPVVMngteE1EWW0CCe7Ea8LJ64zYt5V2b49zI\n68hPqezmUDw/40T+XP8sY2hsCxC8xOsTlL3T8cvJjZEnanSmP1ZxS9pj1fxkA7vc\nE6LmqTv9Pm41l5Aal9QpnypN\n-----END PRIVATE KEY-----";

    fn sa() -> ServiceAccount {
        ServiceAccount {
            client_email: "svc@example.iam.gserviceaccount.com".into(),
            private_key: TEST_KEY.to_string(),
            token_uri: "https://oauth2.example/token".into(),
            project_id: Some("proj".into()),
        }
    }

    fn part(jwt: &str, i: usize) -> serde_json::Value {
        let raw = B64URL.decode(jwt.split('.').nth(i).expect("segment")).expect("base64url");
        serde_json::from_slice(&raw).expect("json")
    }

    #[test]
    fn an_assertion_has_three_segments_and_says_who_it_is() {
        let jwt = assertion(&sa(), "https://example/auth/x", 1_700_000_000).unwrap();
        assert_eq!(jwt.split('.').count(), 3);

        assert_eq!(part(&jwt, 0)["alg"], "RS256");
        assert_eq!(part(&jwt, 0)["typ"], "JWT");

        let claims = part(&jwt, 1);
        assert_eq!(claims["iss"], "svc@example.iam.gserviceaccount.com");
        assert_eq!(claims["scope"], "https://example/auth/x");
        // The audience is the token endpoint named by the key file: the signature commits to
        // it, and posting to a different one is refused.
        assert_eq!(claims["aud"], "https://oauth2.example/token");
        assert_eq!(claims["iat"], 1_700_000_000u64);
        assert_eq!(claims["exp"], 1_700_003_600u64);
    }

    #[test]
    fn the_signature_verifies_against_the_public_half() {
        // The test that makes the rest mean anything: a wrong padding, a wrong digest or a
        // signature over the wrong bytes all produce a well-formed JWT that no server accepts.
        let jwt = assertion(&sa(), "scope", 1_700_000_000).unwrap();
        let (signing_input, sig_b64) = jwt.rsplit_once('.').expect("three segments");

        let private = RsaPrivateKey::from_pkcs8_pem(TEST_KEY.trim()).unwrap();
        let public_pem = private.to_public_key().to_public_key_pem(LineEnding::LF).unwrap();
        let verifying = VerifyingKey::<Sha256>::from_public_key_pem(&public_pem).unwrap();
        let signature =
            rsa::pkcs1v15::Signature::try_from(B64URL.decode(sig_b64).unwrap().as_slice()).unwrap();

        verifying.verify(signing_input.as_bytes(), &signature).expect("signature verifies");
    }

    #[test]
    fn a_key_that_is_not_a_key_says_so_rather_than_producing_a_signature() {
        let mut bad = sa();
        bad.private_key = "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----".into();
        let err = assertion(&bad, "scope", 0).unwrap_err();
        assert!(err.contains("not a usable PKCS#8 private key"), "{err}");
    }

    #[test]
    fn the_token_uri_defaults_when_the_file_omits_it() {
        // Every key file Google issues carries one, but a hand-written fixture may not — and a
        // missing audience would sign an assertion nobody can redeem.
        let parsed: ServiceAccount = serde_json::from_value(serde_json::json!({
            "client_email": "a@b.iam.gserviceaccount.com",
            "private_key": TEST_KEY,
        }))
        .unwrap();
        assert_eq!(parsed.token_uri, "https://oauth2.googleapis.com/token");
    }

    #[test]
    fn the_form_body_carries_the_grant_type_the_endpoint_expects() {
        let body = assertion_form("AAA.BBB.CCC");
        assert!(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"));
        assert!(body.ends_with("assertion=AAA.BBB.CCC"));
    }
}
