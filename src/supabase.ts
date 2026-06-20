import 'react-native-url-polyfill/auto';
import 'react-native-get-random-values';
import { createClient } from '@supabase/supabase-js';

// EXPO_PUBLIC_* variables are embedded at build time by Expo.
// Source: .env.local for local dev; EAS environment variables for EAS builds.
// There is no fallback project. Missing values throw immediately.
const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL;
const SUPABASE_PUBLISHABLE_KEY = process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!SUPABASE_URL) throw new Error('EXPO_PUBLIC_SUPABASE_URL is not set.');
if (!SUPABASE_PUBLISHABLE_KEY) throw new Error('EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY is not set.');

if (__DEV__) {
  try {
    const url = new URL(SUPABASE_URL);
    const ref = url.hostname.split('.')[0];
    console.log('[DEV] Supabase project:', {
      hostname: url.hostname,
      ref,
      build: 'development',
    });
  } catch {
    console.warn('[DEV] Supabase project: EXPO_PUBLIC_SUPABASE_URL is not a valid URL.');
  }
}

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
});
