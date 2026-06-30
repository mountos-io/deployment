// init-hub admin-JWT smoke: build the admin SDK client with the provider private
// key and make one authenticated read. A 200 proves the full auth path (SDK
// signs an EdDSA JWT -> appserv verifies via PROVIDER_VERIFICATION_KEY).
// Uses the PUBLISHED SDK module (no replace) so clients resolve it from the proxy.
package main

import (
  "context"
  "fmt"
  "os"

  sdk "github.com/mountos-io/mountos-admin-sdk/go"
)

func main() {
  c, err := sdk.NewClient(sdk.Config{
    BaseURL:    os.Getenv("MOUNTOS_BASE_URL"),
    PrivateKey: os.Getenv("MOUNTOS_PRIVATE_KEY"),
  })
  if err != nil {
    fmt.Println("FAIL init client:", err)
    os.Exit(1)
  }
  list, err := c.Accounts.List(context.Background(), &sdk.AccountListOptions{Page: 1, Limit: 1})
  if err != nil {
    fmt.Println("FAIL authed read:", err)
    os.Exit(1)
  }
  fmt.Printf("OK admin-JWT auth (accounts total=%d)\n", list.Pagination.Total)
}
