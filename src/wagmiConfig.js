import { defaultWagmiConfig } from '@web3modal/wagmi/react/config';
import { createWeb3Modal } from '@web3modal/wagmi/react';
import { polygon } from 'wagmi/chains';

const projectId = import.meta.env.VITE_WC_PROJECT_ID;
if (!projectId) console.warn('VITE_WC_PROJECT_ID is missing; set it in .env.local.');

const metadata = {
  name: 'GHM21 Protocol',
  description: 'GHM21 P2P Mutual Aid Hub',
  url: typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5173',
  icons: [],
};

export const config = defaultWagmiConfig({ chains: [polygon], projectId: projectId || 'demo', metadata });

createWeb3Modal({ wagmiConfig: config, projectId: projectId || 'demo', defaultChain: polygon });
