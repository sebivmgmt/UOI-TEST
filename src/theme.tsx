import React, { createContext, useCallback, useContext, useMemo, useState } from 'react';
import { Appearance, useColorScheme } from 'react-native';

export type AppTheme = {
  isDark: boolean;
  background: string;
  surface: string;
  surfaceElevated: string;
  surfaceMuted: string;
  textPrimary: string;
  textSecondary: string;
  textMuted: string;
  border: string;
  divider: string;
  brand: string;
  brandBright: string;
  positive: string;
  positiveSurface: string;
  positiveBorder: string;
  negativeSurface: string;
  negativeBorder: string;
  negative: string;
  warning: string;
  warningSurface: string;
  info: string;
  infoSurface: string;
  headerBackground: string;
  tabBarBackground: string;
  activeTabSurface: string;
};

export const lightTheme: AppTheme = {
  isDark: false,
  background: '#F5F7F9',
  surface: '#FFFFFF',
  surfaceElevated: '#FFFFFF',
  surfaceMuted: '#F9FAFB',
  textPrimary: '#111827',
  textSecondary: '#374151',
  textMuted: '#6B7280',
  border: '#E5E7EB',
  divider: '#E5E7EB',
  brand: '#1B5E20',
  brandBright: '#2E7D32',
  positive: '#15803D',
  positiveSurface: '#DCFCE7',
  positiveBorder: '#BBF7D0',
  negative: '#991B1B',
  negativeSurface: '#FEF2F2',
  negativeBorder: '#FECACA',
  warning: '#92400E',
  warningSurface: '#FEF3C7',
  info: '#1D4ED8',
  infoSurface: '#EFF6FF',
  headerBackground: '#FFFFFF',
  tabBarBackground: '#FFFFFF',
  activeTabSurface: '#E8F5E9',
};

export const darkTheme: AppTheme = {
  isDark: true,
  background: '#000000',
  surface: '#0A0A0A',
  surfaceElevated: '#111111',
  surfaceMuted: '#161616',
  textPrimary: '#FFFFFF',
  textSecondary: '#D1D5DB',
  textMuted: '#9CA3AF',
  border: '#262626',
  divider: '#1F1F1F',
  brand: '#2E7D32',
  brandBright: '#66BB6A',
  positive: '#66BB6A',
  positiveSurface: '#07150B',
  positiveBorder: '#234B2B',
  negative: '#FF6B6B',
  negativeSurface: '#180A0D',
  negativeBorder: '#4A252A',
  warning: '#FBBF24',
  warningSurface: '#1A1000',
  info: '#60A5FA',
  infoSurface: '#050A1A',
  headerBackground: '#000000',
  tabBarBackground: '#050505',
  activeTabSurface: '#0D2010',
};

// 'system' = follow the device; 'light' / 'dark' = forced override
export type Preference = 'system' | 'light' | 'dark';
type Scheme = 'light' | 'dark';

type ColorSchemeCtx = {
  preference: Preference;
  scheme: Scheme;
  setPreference: (p: Preference) => void;
};

const ColorSchemeContext = createContext<ColorSchemeCtx>({
  preference: 'system',
  scheme: 'light',
  setPreference: () => {},
});

export function ColorSchemeProvider({ children }: { children: React.ReactNode }) {
  const system = useColorScheme(); // stays live; re-renders on device change
  const [preference, setPreferenceState] = useState<Preference>('system');

  // When preference is 'system', effective scheme tracks the device live.
  const scheme: Scheme =
    preference === 'system'
      ? system === 'dark' ? 'dark' : 'light'
      : preference;

  const setPreference = useCallback((p: Preference) => {
    setPreferenceState(p);
    // Keep native controls (alerts, action sheets, pickers) in sync.
    // null reverts native to device when returning to 'system'.
    Appearance.setColorScheme(p === 'system' ? null : p);
  }, []);

  const value = useMemo(
    () => ({ preference, scheme, setPreference }),
    [preference, scheme, setPreference],
  );

  return (
    <ColorSchemeContext.Provider value={value}>
      {children}
    </ColorSchemeContext.Provider>
  );
}

export function useColorSchemeCtx(): ColorSchemeCtx {
  return useContext(ColorSchemeContext);
}

export function useAppTheme(): AppTheme {
  const { scheme } = useContext(ColorSchemeContext);
  return useMemo(() => (scheme === 'dark' ? darkTheme : lightTheme), [scheme]);
}

export function useSchemePreference(): (p: Preference) => void {
  return useContext(ColorSchemeContext).setPreference;
}
