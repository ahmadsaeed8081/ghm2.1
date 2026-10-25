# GHM21 React with GHmarket wallet integration

Vite + React version using GHmarket's Wagmi and Reown Web3Modal stack. The original app page is preserved in `public/ghm21-app.html`; the app's wallet entry points open the default Reown modal. Polygon Mainnet is configured to match this source's contract network.

## Run locally

1. Copy `.env.example` to `.env.local` and set `VITE_WC_PROJECT_ID` to this app's Reown Cloud project ID.
2. Run `npm install`, then `npm run dev`.
3. Open the localhost URL printed by Vite. Do not open the HTML via `file://`.

## Production deployment

- Configure `VITE_WC_PROJECT_ID` in the deployment provider's build environment before running `npm run build`. Vite embeds `VITE_` values into the client build, so a local `.env.local` is not transferred automatically to a remote build machine.
- In Reown Cloud, allowlist the exact production origin for this project's Project ID (for example `https://app.example.com`). Scheme, hostname, and any port must match the deployed origin. Localhost is always allowed; allowlist changes can take about 15 minutes to apply.
- Use a dedicated Reown Project ID for this app rather than reusing another app's ID.
