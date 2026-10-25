# GHM21 React with GHmarket wallet integration

Vite + React version using GHmarket's Wagmi and Reown Web3Modal stack. The original app page is preserved in `public/ghm21-app.html`; the app's wallet entry points open the default Reown modal. Polygon Mainnet is configured to match this source's contract network.

## Run

1. Copy `.env.example` to `.env.local` and set `VITE_WC_PROJECT_ID`.
2. Run `npm install`, then `npm run dev`.
3. Open the localhost URL printed by Vite. Do not open the HTML via `file://`.
