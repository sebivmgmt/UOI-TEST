// src/auth.ts
import { supabase } from './supabase';

export async function signInWithEmail(email: string) {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { shouldCreateUser: true },
  });
  if (error) throw error;
}

export async function getSession() {
  const { data } = await supabase.auth.getSession();
  return data.session; // Session | null
}

export function onAuthStateChange(cb: (signedIn: boolean) => void) {
  const { data: { subscription } } = supabase.auth.onAuthStateChange(
    (_event, session) => cb(!!session)
  );
  return subscription; // caller should unsubscribe()
}

export async function signOut() {
  await supabase.auth.signOut();
}