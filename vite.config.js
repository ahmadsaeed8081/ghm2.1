import { defineConfig, loadEnv } from 'vite';

export default defineConfig(({ mode }) => {
  const loaded = loadEnv(mode, process.cwd(), 'VITE_');
  const projectId = process.env.VITE_WC_PROJECT_ID || loaded.VITE_WC_PROJECT_ID;
  if (!projectId || projectId === 'your_reown_project_id') {
    throw new Error('Set VITE_WC_PROJECT_ID in the build environment or .env.local before building.');
  }
  return {};
});
