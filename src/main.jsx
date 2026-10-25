import React, { StrictMode, useCallback, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider, useAccount, useDisconnect } from 'wagmi';
import { useWeb3Modal } from '@web3modal/wagmi/react';
import { config } from './wagmiConfig';
import './styles.css';

const queryClient = new QueryClient();

function WalletBridge({ frameRef, frameLoaded }) {
  const { open } = useWeb3Modal();
  const { isConnected, connector, address } = useAccount();
  const { disconnectAsync } = useDisconnect();
  const providerRef = useRef(null);
  const pendingConnect = useRef(false);
  const attached = useRef(new WeakSet());

  const send = useCallback((kind, ...args) => {
    const child = frameRef.current?.contentWindow;
    if (!child) return;
    if (kind === 'ready') child.ghmHandleProviderReady?.(...args);
    if (kind === 'event') child.ghmHandleProviderEvent?.(...args);
    if (kind === 'error') child.ghmHandleProviderError?.(...args);
  }, [frameRef]);

  const getProvider = useCallback(async () => {
    if (!connector) throw new Error('No wallet connector is available.');
    const provider = providerRef.current || await connector.getProvider();
    providerRef.current = provider;
    if (provider && !attached.current.has(provider) && typeof provider.on === 'function') {
      attached.current.add(provider);
      for (const event of ['accountsChanged', 'chainChanged', 'disconnect']) {
        provider.on(event, (value) => send('event', event, value));
      }
    }
    return provider;
  }, [connector, send]);

  useEffect(() => {
    if (!isConnected || !connector || !frameLoaded) {
      if (!isConnected) providerRef.current = null;
      return;
    }
    let cancelled = false;
    const wasPendingConnect = pendingConnect.current;
    pendingConnect.current = false;
    getProvider().then(() => {
      if (cancelled) return;
      // Wagmi owns session restoration; always synchronize the iframe from its connected state.
      send('ready', !wasPendingConnect);
    }).catch((error) => send('error', error?.message || 'Unable to access connected wallet.'));
    return () => { cancelled = true; };
  }, [connector, frameLoaded, getProvider, isConnected, send]);

  const requestWalletRpc = useCallback(async (method, params = []) => {
    const provider = await getProvider();
    return provider.request({ method, params });
  }, [getProvider]);

  const openWalletModal = useCallback(async () => {
    if (isConnected && connector) {
      pendingConnect.current = false;
      try {
        await getProvider();
        const child = frameRef.current?.contentWindow;
        const appAddress = child?.ghmConnectedWalletAddress;
        if (!address || appAddress?.toLowerCase() !== address.toLowerCase()) send('ready', true);
      } catch (error) {
        send('error', error?.message || 'Unable to sync the connected wallet.');
      }
    } else {
      pendingConnect.current = true;
    }
    await open();
  }, [address, connector, frameRef, getProvider, isConnected, open, send]);

  const disconnectWallet = useCallback(async () => {
    try { await disconnectAsync(); } finally { providerRef.current = null; }
  }, [disconnectAsync]);

  useEffect(() => {
    const bridge = { openModal: openWalletModal, request: requestWalletRpc, disconnect: disconnectWallet };
    window.ghmWalletBridge = bridge;
    const child = frameRef.current?.contentWindow;
    if (child) {
      child.ghmOpenWalletModal = openWalletModal;
      child.ghmWagmiProvider = { request: ({ method, params = [] }) => requestWalletRpc(method, params) };
    }
    return () => {
      if (window.ghmWalletBridge === bridge) delete window.ghmWalletBridge;
      try { if (child?.ghmOpenWalletModal === openWalletModal) delete child.ghmOpenWalletModal; } catch {}
    };
  }, [disconnectWallet, frameLoaded, frameRef, openWalletModal, requestWalletRpc]);

  return null;
}

function App() {
  const frameRef = useRef(null);
  const [frameLoaded, setFrameLoaded] = useState(false);
  return <main className="app-shell">
    <WalletBridge frameRef={frameRef} frameLoaded={frameLoaded} />
    <iframe ref={frameRef} className="legacy-app" src={`/ghm21-app.html${window.location.search}`} title="GHM21 P2P Mutual Aid Hub" allow="clipboard-read; clipboard-write; fullscreen" onLoad={() => setFrameLoaded(true)} />
  </main>;
}

createRoot(document.getElementById('root')).render(
  <StrictMode><WagmiProvider config={config}><QueryClientProvider client={queryClient}><App /></QueryClientProvider></WagmiProvider></StrictMode>,
);
