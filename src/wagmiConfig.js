import { defaultWagmiConfig } from '@web3modal/wagmi/react/config';
import { createWeb3Modal } from '@web3modal/wagmi/react';
import { polygon } from 'wagmi/chains';

const projectId = import.meta.env.VITE_WC_PROJECT_ID;
if (!projectId || projectId === 'your_reown_project_id') {
  throw new Error('VITE_WC_PROJECT_ID is required. Configure it before starting or building the app.');
}

const metadata = {
  name: 'GHM21 Protocol',
  description: 'GHM21 P2P Mutual Aid Hub',
  url: typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5173',
  icons: [],
};

export const config = defaultWagmiConfig({ chains: [polygon], projectId, metadata });

createWeb3Modal({ wagmiConfig: config, projectId, defaultChain: polygon });
