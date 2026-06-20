// src/utils/resolveProfile.ts
import { supabase } from "../supabase";

export type ResolvedProfile = {
  id: string;
  public_name?: string | null;
  iou_hash?: string | null;
};

export async function resolveProfile(identifierRaw: string): Promise<{
  profile?: ResolvedProfile;
  invitedEmail?: string | null;
}> {
  const identifier = identifierRaw.trim();
  if (!identifier) return {};

  const { data, error } = await supabase.functions.invoke("search-counterparty", {
    body: { query: identifier },
  });

  if (!error && data?.results?.length) {
    const first = data.results[0] as any;
    return {
      profile: {
        id: first.id,
        public_name: first.display_name || first.full_name || null,
        iou_hash: first.iou_hash ?? null,
      },
    };
  }

  if (identifier.includes("@")) return { invitedEmail: identifier.toLowerCase() };
  return {};
}