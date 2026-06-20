import { useState, useEffect } from "react";
import { supabase } from "../supabase";

export type ProfileLite = {
  id: string;
  iou_hash?: string | null;
  public_name: string | null;
  avatar_url?: string | null;
  iou_score?: number | null;
};

export function useRecentCounterparties(): {
  recent: ProfileLite[];
  recentLoading: boolean;
} {
  const [recent, setRecent] = useState<ProfileLite[]>([]);
  const [recentLoading, setRecentLoading] = useState(false);

  useEffect(() => {
    let active = true;

    const load = async () => {
      setRecentLoading(true);
      try {
        const me = (await supabase.auth.getUser()).data.user?.id;
        if (!me || !active) return;

        const { data, error } = await supabase
          .from("ious")
          .select("lender_id, borrower_id, created_at")
          .or(`lender_id.eq.${me},borrower_id.eq.${me}`)
          .order("created_at", { ascending: false })
          .limit(40);

        if (error || !active) return;

        const ids = Array.from(
          new Set(
            (data ?? [])
              .map((r: any) => (r.lender_id === me ? r.borrower_id : r.lender_id))
              .filter(Boolean)
          )
        ).slice(0, 10) as string[];

        if (ids.length === 0) {
          if (active) setRecent([]);
          return;
        }

        const { data: profs } = await supabase
          .from("profile_directory")
          .select("id, iou_hash, public_name, avatar_url, iou_score")
          .in("id", ids);

        if (!active) return;

        const map = new Map((profs ?? []).map((p: any) => [p.id, p]));
        const safeRecent: ProfileLite[] = ids
          .map((id) => map.get(id))
          .filter(Boolean)
          .map((p: any) => ({
            id: p.id,
            iou_hash: p.iou_hash ?? null,
            public_name: p.public_name ?? null,
            avatar_url: p.avatar_url ?? null,
            iou_score: p.iou_score ?? null,
          }));

        if (active) setRecent(safeRecent);
      } catch {
        // ignore — recent counterparties are best-effort
      } finally {
        if (active) setRecentLoading(false);
      }
    };

    void load();

    return () => {
      active = false;
    };
  }, []);

  return { recent, recentLoading };
}
