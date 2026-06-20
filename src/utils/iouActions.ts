// src/utils/iouActions.ts
import { Alert } from 'react-native';
import { supabase } from '../supabase';

export async function archiveLoan(iouId: string) {
  const { data, error } = await supabase.rpc('archive_iou', { p_iou: iouId, p_archived: true });
  if (error) throw error;
  return data;
}

export async function unarchiveLoan(iouId: string) {
  const { data, error } = await supabase.rpc('archive_iou', { p_iou: iouId, p_archived: false });
  if (error) throw error;
  return data;
}

export async function deleteLoanSoft(iouId: string) {
  const ok = await new Promise<boolean>((resolve) => {
    Alert.alert(
      'Delete IOU?',
      'This removes it from active lists. You can only restore if it was not permanently removed later.',
      [
        { text: 'Cancel', style: 'cancel', onPress: () => resolve(false) },
        { text: 'Delete', style: 'destructive', onPress: () => resolve(true) },
      ]
    );
  });
  if (!ok) return null;

  const { data, error } = await supabase.rpc('delete_iou_soft', { p_iou: iouId });
  if (error) throw error;
  return data;
}

export async function restoreLoan(iouId: string) {
  const { data, error } = await supabase.rpc('restore_iou', { p_iou: iouId });
  if (error) throw error;
  return data;
}