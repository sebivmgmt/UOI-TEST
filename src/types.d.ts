// src/types.d.ts
export type RootStackParamList = {
  Home: undefined;
  Archived: undefined;
  NewLoan: { id?: string } | undefined;          // schedule-from-existing supported
  LoanDetail: { id?: string; iou_id?: string };  // accepts either prop
  Profile: undefined;
  VerifyPhone: undefined;
  PreviewSign: { id: string } | undefined;
};

declare global {
  namespace ReactNavigation {
    interface RootParamList extends RootStackParamList {}
  }
}