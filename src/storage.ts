// src/storage.ts
import AsyncStorage from '@react-native-async-storage/async-storage';
import { supabase } from './supabase';

export type LoanStatus = 'requested' | 'active' | 'declined' | 'completed';

export interface Loan {
  id: string;
  title: string;
  principal: number;
  amountRemaining: number;
  status: LoanStatus;
  createdAt: string;
}

const KEY = 'IOU_LOANS_V2';

// ---------- cache helpers ----------
async function cacheSet(loans: Loan[]) {
  await AsyncStorage.setItem(KEY, JSON.stringify(loans));
}
export async function cacheGet(): Promise<Loan[]> {
  const raw = await AsyncStorage.getItem(KEY);
  return raw ? JSON.parse(raw) : [];
}

// ---------- reads ----------
export async function getLoans(): Promise<Loan[]> {
  const { data } = await supabase.auth.getSession();
  if (!data.session) return cacheGet();

  const { data: rows, error } = await supabase
    .from('loans')
    .select('*')
    .order('created_at', { ascending: false });

  if (error) return cacheGet();

  const loans: Loan[] = (rows ?? []).map((r: any) => ({
    id: r.id,
    title: r.title,
    principal: Number(r.principal),
    amountRemaining: Number(r.amount_remaining),
    status: r.status,
    createdAt: r.created_at,
  }));
  await cacheSet(loans);
  return loans;
}

export async function getLoan(id: string): Promise<Loan | null> {
  const cached = await cacheGet();
  const hit = cached.find(l => l.id === id);
  if (hit) return hit;

  const { data: row, error } = await supabase
    .from('loans')
    .select('*')
    .eq('id', id)
    .single();

  if (error || !row) return null;

  const loan: Loan = {
    id: row.id,
    title: row.title,
    principal: Number(row.principal),
    amountRemaining: Number(row.amount_remaining),
    status: row.status,
    createdAt: row.created_at,
  };
  await cacheSet([loan, ...cached.filter(l => l.id !== id)]);
  return loan;
}

// ---------- writes ----------
export async function addLoan(partial: Omit<Loan, 'id' | 'createdAt'>): Promise<Loan> {
  const { data } = await supabase.auth.getSession();
  if (!data.session) throw new Error('Not signed in');

  const { data: row, error } = await supabase
    .from('loans')
    .insert({
      user_id: data.session.user.id,
      title: partial.title,
      principal: partial.principal,
      amount_remaining: partial.amountRemaining,
      status: partial.status,
    })
    .select()
    .single();

  if (error) throw error;

  const loan: Loan = {
    id: row.id,
    title: row.title,
    principal: Number(row.principal),
    amountRemaining: Number(row.amount_remaining),
    status: row.status,
    createdAt: row.created_at,
  };

  const cached = await cacheGet();
  await cacheSet([loan, ...cached]);
  return loan;
}


export async function updateLoan(
  id: string,
  patch: Partial<Pick<Loan, 'title' | 'status' | 'principal' | 'amountRemaining'>>
): Promise<void> {
  const update: any = {};
  if (patch.title !== undefined) update.title = patch.title;
  if (patch.status !== undefined) update.status = patch.status;
  if (patch.principal !== undefined) update.principal = patch.principal;
  if (patch.amountRemaining !== undefined) update.amount_remaining = patch.amountRemaining;

  const { error } = await supabase.from('loans').update(update).eq('id', id);
  if (error) throw error;

  await getLoans(); // refresh cache
}