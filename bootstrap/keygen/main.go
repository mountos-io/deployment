// keygen emits fresh mountOS hub key material as JSON (base64 std encoding).
// Run ONCE by the operator at bootstrap; seed-vault.sh writes the values into
// Vault. Formats match what appserv expects: ed25519 private = 64-byte raw,
// public = 32-byte raw, HMAC / api-master = 32 random bytes. No dependencies.
//
// appserv also has an equivalent `appserv keygen` subcommand (identical output
// shape) for use on an already-provisioned Linux node. This standalone tool
// stays the primary path for the deploy package's seed scripts: clients only
// ever get the published n.sh appserv binary (linux/{amd64,arm64} only, per
// the production release matrix), not the mountos-servers source needed to
// build appserv for their own workstation — this tiny zero-dependency binary
// is what actually runs cross-platform for them.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
)

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func randB64(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	return b64(b)
}

func main() {
	appPub, appPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	admPub, admPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	dataPub, dataPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	gcPub, gcPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	blkPub, blkPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	// dashboardPub/Priv: mountos-admin-client's own session/refresh JWT pair
	// (DASHBOARD_SIGNING_KEY/DASHBOARD_VERIFICATION_KEY).
	dashPub, dashPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	// provider2dashPub/Priv: the operator's own ephemeral-login keypair. The
	// operator's backend signs short-lived (~60s) login tokens with the
	// private half; the dashboard verifies with the public half
	// (PROVIDER2DASHBOARD_VERIFICATION_KEY). Generated here so a self-operated
	// deployment (no separate customer backend) can mint its own login tokens.
	provPub, provPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
	// Hub seed uses appserv/admin/hmac/api_master; region seed uses dataserv/gcserv
	// plus blockserv (region-scoped, key material generated unconditionally
	// regardless of whether the service is actually run there). dashboard_*/
	// provider2dashboard_* are generated unconditionally too, regardless of
	// whether mountos-admin-client is actually deployed.
	// Each consumer reads only the fields it needs; the rest are ignored.
	out := map[string]string{
		"appserv_signing":                 b64(appPriv),
		"appserv_verification":            b64(appPub),
		"admin_private":                   b64(admPriv), // operator keeps this safe; signs admin SDK JWTs
		"admin_public":                    b64(admPub),  // -> PROVIDER_VERIFICATION_KEY
		"dashboard_hmac":                  randB64(32),
		"api_master":                      randB64(32),
		"dataserv_signing":                b64(dataPriv),
		"dataserv_verification":           b64(dataPub),
		"gcserv_signing":                  b64(gcPriv),
		"gcserv_verification":             b64(gcPub),
		"blockserv_signing":               b64(blkPriv),
		"blockserv_verification":          b64(blkPub),
		"dashboard_signing":               b64(dashPriv), // -> DASHBOARD_SIGNING_KEY
		"dashboard_verification":          b64(dashPub),  // -> DASHBOARD_VERIFICATION_KEY
		"provider2dashboard_signing":      b64(provPriv), // operator keeps this safe; mints dashboard login tokens
		"provider2dashboard_verification": b64(provPub),  // -> PROVIDER2DASHBOARD_VERIFICATION_KEY
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(1)
	}
}
