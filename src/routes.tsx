import React, { useEffect, useState } from "react";
import { ActivityIndicator, TouchableOpacity, View, StyleSheet } from "react-native";
import { NavigationContainer, DefaultTheme, DarkTheme, useNavigation } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { House, Plus, Users, ShieldCheck, User } from "lucide-react-native";
import { useAppTheme } from "./theme";
import { supabase } from "./supabase";
import SplashScreen from "./screens/SplashScreen";

import Home from "./screens/Home";
import NewLoan from "./screens/NewLoan";
import LoanDetail from "./screens/LoanDetail";
import Profile from "./screens/Profile";
import VerifyPhone from "./screens/VerifyPhone";
import VerifyIdentity from "./screens/VerifyIdentity";
import Archived from "./screens/Archived";
import PreviewSign from "./screens/PreviewSign";
import Auth from "./screens/Auth";
import Receipt from "./screens/ReceiptScreen";
import ConfirmPayment from "./screens/ConfirmPayment";
import AchPayment from "./screens/AchPayment";
import ScoreHistoryScreen from "./screens/ScoreHistoryScreen";
import PersonScreen from "./screens/PersonScreen";
import LinkBank from "./screens/LinkBank";
import SelectBankAccount from "./screens/SelectBankAccount";
import SearchUsersScreen from "./screens/SearchUsersScreen";
import Inbox from "./screens/Inbox";
import IousListScreen from "./screens/IousListScreen";
import RequestExtension from "./screens/RequestExtension";
import SplitReceiptScreen from "./screens/SplitReceiptScreen";
import ReceiptCameraScreen from "./screens/ReceiptCameraScreen";
import ReceiptReviewScreen from "./screens/ReceiptReviewScreen";
import ReceiptParticipantsScreen from "./screens/ReceiptParticipantsScreen";
import AssignItemsScreen from "./screens/AssignItemsScreen";
import ReceiptSummaryScreen from "./screens/ReceiptSummaryScreen";
import ReceiptPaymentConfirmScreen from "./screens/ReceiptPaymentConfirmScreen";
import { ReceiptSplitProvider } from "./context/receiptSplitContext";
import MoneyActionScreen from "./screens/MoneyActionScreen";
import NewIouScreen from "./screens/NewIouScreen";
import TrustReportScreen from "./screens/TrustReportScreen";
import ViewTrustReportScreen from "./screens/ViewTrustReportScreen";
import TrustIntroScreen from "./screens/TrustIntroScreen";
import TrustHomeScreen from "./screens/TrustHomeScreen";
import MissedPaymentImpactScreen from "./screens/MissedPaymentImpactScreen";

const BRAND = "#1B5E20";

export type RootStackParamList = {
  Auth: undefined;
  IOUsList: undefined;
  Home: undefined;
  Archived: undefined;
  SearchUsers: undefined;
  Inbox: undefined;
  MoneyAction: undefined;
  NewLoan:
    | {
        id?: string;
        presetBorrowerId?: string;
        presetBorrowerName?: string | null;
        presetBorrowerEmail?: string | null;
        presetBorrowerPhone?: string | null;
        presetBorrowerPhoneVerified?: boolean | null;
        mode?: "lend" | "borrow";
      }
    | undefined;
  LoanDetail:
    | {
        iouId?: string;
        iou_id?: string;
        loanId?: string;
        loan_id?: string;
        id?: string;
        direction?: "in" | "out";
        initialTab?: 'overview' | 'payments' | 'score' | 'estimate';
        focusPaymentId?: string;
      }
    | undefined;
  Receipt:
    | {
        paymentId: string;
        iouId?: string;
        iou_id?: string;
        loanId?: string;
        loan_id?: string;
        receiptHash?: string;
      }
    | undefined;
  ConfirmPayment:
    | {
        paymentId: string;
        amount: number;
        iouId?: string;
        iou_id?: string;
        loanId?: string;
        loan_id?: string;
      }
    | undefined;
  AchPayment:
    | {
        paymentId: string;
        amount: number;
        due: string;
        iouId?: string;
        iou_id?: string;
      }
    | undefined;
  LinkBank:
    | {
      returnTo?: string;
      paymentId?: string;
      iouId?: string;
      iou_id?: string;
      loanId?: string;
      loan_id?: string;
    } | undefined;
  SelectBankAccount:
    | {
        accounts: Array<{
          plaid_account_id: string;
          account_name: string | null;
          official_name: string | null;
          mask: string | null;
          type: string | null;
          subtype: string | null;
          verification_status: string | null;
          is_active: boolean;
        }>;
        institutionName?: string | null;
        plaidItemId: string;
        returnTo?: string;
        paymentId?: string;
        iouId?: string;
        iou_id?: string;
        loanId?: string;
        loan_id?: string;
      }
    | undefined;
  Profile: undefined;
  VerifyPhone: undefined;
  VerifyIdentity: undefined;
  PreviewSign: { id: string };
  ScoreHistory: undefined;
  Person:
    | {
        personId?: string;
        id?: string;
      }
    | undefined;
  RequestExtension: {
    paymentId: string;
    iouId: string;
    scheduledAt: string;
    paymentAmount?: number;
    title?: string | null;
  };
  NewIouScreen: { initialRole?: "lend" | "borrow" } | undefined;
  TrustReport: undefined;
  ViewTrustReport: { ownerUserId: string; ownerName?: string };
  TrustIntro: undefined;
  TrustHome: undefined;
  SplitReceipt: undefined;
  ReceiptCamera: undefined;
  ReceiptReview: undefined;
  ReceiptParticipants: undefined;
  AssignItems: undefined;
  ReceiptSummary: undefined;
  ReceiptPaymentConfirm: { recipientName: string; payerName: string; amountCents: number };
  MissedPaymentImpact: { iouId: string; paymentId: string };
};

type GateState = "auth" | "phone" | "identity" | "app";

type ProfileGateRow = {
  phone_verified?: boolean | null;
  identity_status?: string | null;
};

const Stack = createNativeStackNavigator<RootStackParamList>();
const Tab = createBottomTabNavigator();

function usePendingIouCount(): number {
  const [count, setCount] = useState(0);

  useEffect(() => {
    let userId: string | null = null;
    let cancelled = false;

    async function refresh() {
      if (!userId) {
        const { data: { user } } = await supabase.auth.getUser();
        userId = user?.id ?? null;
      }
      if (!userId || cancelled) return;
      const { count: c } = await supabase
        .from("ious")
        .select("id", { count: "exact", head: true })
        .eq("requested_action_by", userId)
        .eq("status", "open")
        .is("activated_at", null)
        .is("deleted_at", null);
      if (!cancelled) setCount(c ?? 0);
    }

    void refresh();

    const channel = supabase
      .channel("tab-badge-ious")
      .on("postgres_changes", { event: "*", schema: "public", table: "ious" }, () => {
        void refresh();
      })
      .subscribe();

    return () => {
      cancelled = true;
      supabase.removeChannel(channel);
    };
  }, []);

  return count;
}

function normalizeIdentityStatus(value?: string | null) {
  const raw = (value || "").trim().toLowerCase();

  if (raw === "verified") return "verified";
  if (raw === "retry") return "retry";
  if (raw === "document") return "document";
  if (raw === "kba") return "kba";
  if (raw === "suspended") return "suspended";
  if (raw === "deactivated") return "deactivated";

  if (
    raw === "pending" ||
    raw === "review" ||
    raw === "in_review" ||
    raw === "received" ||
    raw === "submitted"
  ) {
    return "pending";
  }

  return "unverified";
}

// Invisible spacer — occupies the center slot so the 2 real tabs on each side
// spread naturally away from the FAB. No visual output, no touch area.
function FabSpacer() {
  return null;
}

// Provides the computed dock clearance (pixels content must leave at the bottom)
// to every stack navigator so they derive it from live insets rather than a hardcoded constant.
const DockContext = React.createContext(92);

// FAB overlay: positioned dynamically so it stays centered on the dock on all devices.
function NewIouFab({ dockBottom }: { dockBottom: number }) {
  const navigation = useNavigation<any>();
  const { isDark } = useAppTheme();
  return (
    <View style={[ts.fabContainer, { bottom: dockBottom + 4 }]} pointerEvents="box-none">
      <TouchableOpacity
        style={[ts.fab, isDark && { shadowOpacity: 0, elevation: 0 }]}
        onPress={() => navigation.navigate("HomeTab", { screen: "MoneyAction" })}
        activeOpacity={0.78}
        hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
        accessibilityLabel="Create IOU"
        accessibilityRole="button"
      >
        <Plus size={28} color="#fff" strokeWidth={2.5} />
      </TouchableOpacity>
    </View>
  );
}

// App tab navigator wrapping common screens.
// Tab order: Home | People | [FAB] | Trust | Profile
// The pending IOU badge lives on Home (moved from the old IOUs tab).
function AppTabs() {
  const pendingCount = usePendingIouCount();
  const insets = useSafeAreaInsets();
  const theme = useAppTheme();

  // Dock sits 8 pt above the home indicator (or 8 pt from the physical edge on SE).
  const dockBottom = Math.max(8, insets.bottom + 4);
  // Clearance scrollable content must leave at the bottom of every stack screen.
  const dockClearance = dockBottom + 64 + 12;

  const tabBarStyle = {
    ...ts.tabBar,
    bottom: dockBottom,
    backgroundColor: theme.tabBarBackground,
    ...(theme.isDark && {
      shadowOpacity: 0 as const,
      elevation: 0,
      borderWidth: 1,
      borderColor: theme.border,
    }),
  };

  return (
    <DockContext.Provider value={dockClearance}>
      <View style={{ flex: 1, backgroundColor: theme.background }}>
        <Tab.Navigator
          screenOptions={{
            headerShown: false,
            tabBarActiveTintColor: theme.brandBright,
            tabBarInactiveTintColor: theme.textMuted,
            tabBarShowLabel: false,
            tabBarStyle,
          }}
        >
          <Tab.Screen
            name="HomeTab"
            component={HomeStack}
            options={{
              tabBarBadge: pendingCount > 0 ? pendingCount : undefined,
              tabBarAccessibilityLabel: "Home",
              tabBarIcon: ({ color, focused }) => (
                <View style={[ts.iconWrap, focused && { backgroundColor: theme.activeTabSurface }]}>
                  <House size={22} color={color} strokeWidth={focused ? 2.5 : 1.75} />
                </View>
              ),
            }}
          />
          <Tab.Screen
            name="PeopleTab"
            component={PeopleStack}
            options={{
              tabBarAccessibilityLabel: "People",
              tabBarIcon: ({ color, focused }) => (
                <View style={[ts.iconWrap, focused && { backgroundColor: theme.activeTabSurface }]}>
                  <Users size={22} color={color} strokeWidth={focused ? 2.5 : 1.75} />
                </View>
              ),
            }}
          />
          {/* Invisible spacer keeps left/right icon groups away from the FAB */}
          <Tab.Screen
            name="FabSpacer"
            component={FabSpacer}
            options={{
              tabBarButton: () => <View style={ts.fabGap} />,
            }}
          />
          <Tab.Screen
            name="TrustTab"
            component={TrustStack}
            options={{
              tabBarAccessibilityLabel: "Trust",
              tabBarIcon: ({ color, focused }) => (
                <View style={[ts.iconWrap, focused && { backgroundColor: theme.activeTabSurface }]}>
                  <ShieldCheck size={22} color={color} strokeWidth={focused ? 2.5 : 1.75} />
                </View>
              ),
            }}
          />
          <Tab.Screen
            name="Profile"
            component={ProfileStack}
            options={{
              tabBarAccessibilityLabel: "Profile",
              tabBarIcon: ({ color, focused }) => (
                <View style={[ts.iconWrap, focused && { backgroundColor: theme.activeTabSurface }]}>
                  <User size={22} color={color} strokeWidth={focused ? 2.5 : 1.75} />
                </View>
              ),
            }}
          />
        </Tab.Navigator>
        <NewIouFab dockBottom={dockBottom} />
      </View>
    </DockContext.Provider>
  );
}

// Home stack — includes IOUsList so IOUs remain reachable after removing the IOUs tab.
function HomeStack() {
  const dockClearance = React.useContext(DockContext);
  const theme = useAppTheme();
  const screenOptions = {
    headerStyle: { backgroundColor: theme.headerBackground },
    headerTintColor: theme.textPrimary,
    contentStyle: { backgroundColor: theme.background, paddingBottom: dockClearance },
    statusBarStyle: (theme.isDark ? 'light' : 'dark') as 'light' | 'dark',
  };

  return (
    <ReceiptSplitProvider>
      <Stack.Navigator screenOptions={screenOptions}>
        <Stack.Screen name="Home" component={Home} options={{ title: "IOU" }} />
        <Stack.Screen name="IOUsList" component={IousListScreen} options={{ title: "My IOUs" }} />
        <Stack.Screen name="Inbox" component={Inbox} options={{ title: "IOU Inbox" }} />
        <Stack.Screen name="Profile" component={Profile} options={{ title: "Profile" }} />
        <Stack.Screen name="Archived" component={Archived} options={{ title: "Archived" }} />
        <Stack.Screen name="SearchUsers" component={SearchUsersScreen} options={{ title: "Search Users" }} />
        <Stack.Screen name="Person" component={PersonScreen} options={{ title: "Person" }} />
        <Stack.Screen name="NewLoan" component={NewLoan} options={{ title: "New IOU" }} />
        <Stack.Screen name="NewIouScreen" component={NewIouScreen} options={{ title: "New IOU", headerShown: false }} />
        <Stack.Screen name="LoanDetail" component={LoanDetail} options={{ title: "Loan Detail" }} />
        <Stack.Screen name="ConfirmPayment" component={ConfirmPayment} options={{ title: "Confirm Payment" }} />
        <Stack.Screen name="AchPayment" component={AchPayment} options={{ title: "ACH Payment" }} />
        <Stack.Screen name="LinkBank" component={LinkBank} options={{ title: "Link Bank" }} />
        <Stack.Screen name="SelectBankAccount" component={SelectBankAccount} options={{ title: "Select Bank Account" }} />
        <Stack.Screen name="Receipt" component={Receipt} options={{ title: "Payment Receipt" }} />
        <Stack.Screen name="VerifyPhone" component={VerifyPhone} options={{ title: "Verify Phone" }} />
        <Stack.Screen name="VerifyIdentity" component={VerifyIdentity} options={{ title: "Verify Identity" }} />
        <Stack.Screen name="PreviewSign" component={PreviewSign} options={{ title: "Preview & Sign" }} />
        <Stack.Screen name="ScoreHistory" component={ScoreHistoryScreen} options={{ title: "Score History" }} />
        <Stack.Screen name="TrustReport" component={TrustReportScreen} options={{ title: "Trust Report" }} />
        <Stack.Screen name="ViewTrustReport" component={ViewTrustReportScreen} options={{ title: "Trust Report" }} />
        <Stack.Screen name="TrustIntro" component={TrustIntroScreen} options={{ headerShown: false }} />
        <Stack.Screen name="TrustHome" component={TrustHomeScreen} options={{ title: "IOU Trust" }} />
        <Stack.Screen name="RequestExtension" component={RequestExtension} options={{ title: "Request Extension" }} />
        <Stack.Screen
          name="MoneyAction"
          component={MoneyActionScreen}
          options={{ title: "", presentation: "formSheet" }}
        />
        <Stack.Screen name="SplitReceipt" component={SplitReceiptScreen} options={{ title: "Split Receipt" }} />
        <Stack.Screen name="ReceiptCamera" component={ReceiptCameraScreen} options={{ title: "Scan Receipt" }} />
        <Stack.Screen name="ReceiptReview" component={ReceiptReviewScreen} options={{ title: "Review Items" }} />
        <Stack.Screen name="ReceiptParticipants" component={ReceiptParticipantsScreen} options={{ title: "Add Friends" }} />
        <Stack.Screen name="AssignItems" component={AssignItemsScreen} options={{ title: "Assign Items" }} />
        <Stack.Screen name="ReceiptSummary" component={ReceiptSummaryScreen} options={{ title: "Split Summary" }} />
        <Stack.Screen name="ReceiptPaymentConfirm" component={ReceiptPaymentConfirmScreen} options={{ title: "Confirm Payment" }} />
        <Stack.Screen name="MissedPaymentImpact" component={MissedPaymentImpactScreen} options={{ title: "Payment Impact" }} />
      </Stack.Navigator>
    </ReceiptSplitProvider>
  );
}

// Trust stack — root of the Trust bottom tab.
// Step 2: promoted to a real tab. IOUsList moved to HomeStack to free this slot.
function TrustStack() {
  const dockClearance = React.useContext(DockContext);
  const theme = useAppTheme();
  const screenOptions = {
    headerStyle: { backgroundColor: theme.headerBackground },
    headerTintColor: theme.textPrimary,
    contentStyle: { backgroundColor: theme.background, paddingBottom: dockClearance },
    statusBarStyle: (theme.isDark ? 'light' : 'dark') as 'light' | 'dark',
  };

  return (
    <Stack.Navigator screenOptions={screenOptions}>
      <Stack.Screen name="TrustHome" component={TrustHomeScreen} options={{ title: "IOU Trust" }} />
      <Stack.Screen name="TrustReport" component={TrustReportScreen} options={{ title: "Trust Report" }} />
      <Stack.Screen name="ViewTrustReport" component={ViewTrustReportScreen} options={{ title: "Trust Report" }} />
      <Stack.Screen name="TrustIntro" component={TrustIntroScreen} options={{ headerShown: false }} />
      <Stack.Screen name="ScoreHistory" component={ScoreHistoryScreen} options={{ title: "Score History" }} />
    </Stack.Navigator>
  );
}

// People stack — gives SearchUsersScreen a proper header and safe-area handling.
function PeopleStack() {
  const dockClearance = React.useContext(DockContext);
  const theme = useAppTheme();
  const screenOptions = {
    headerStyle: { backgroundColor: theme.headerBackground },
    headerTintColor: theme.textPrimary,
    contentStyle: { backgroundColor: theme.background, paddingBottom: dockClearance },
    statusBarStyle: (theme.isDark ? 'light' : 'dark') as 'light' | 'dark',
  };

  return (
    <Stack.Navigator screenOptions={screenOptions}>
      <Stack.Screen name="SearchUsers" component={SearchUsersScreen} options={{ title: "Friends" }} />
      <Stack.Screen name="Person" component={PersonScreen} options={{ title: "Person" }} />
      <Stack.Screen name="NewLoan" component={NewLoan} options={{ title: "New IOU" }} />
      <Stack.Screen name="ViewTrustReport" component={ViewTrustReportScreen} options={{ title: "Trust Report" }} />
    </Stack.Navigator>
  );
}

// Profile stack — trust screens kept here temporarily so existing Profile
// navigation buttons keep working while the Trust tab is being verified.
function ProfileStack() {
  const dockClearance = React.useContext(DockContext);
  const theme = useAppTheme();
  const screenOptions = {
    headerStyle: { backgroundColor: theme.headerBackground },
    headerTintColor: theme.textPrimary,
    contentStyle: { backgroundColor: theme.background, paddingBottom: dockClearance },
    statusBarStyle: (theme.isDark ? 'light' : 'dark') as 'light' | 'dark',
  };

  return (
    <Stack.Navigator screenOptions={screenOptions}>
      <Stack.Screen name="Profile" component={Profile} options={{ title: "Profile" }} />
      <Stack.Screen name="VerifyPhone" component={VerifyPhone} options={{ title: "Verify Phone" }} />
      <Stack.Screen name="VerifyIdentity" component={VerifyIdentity} options={{ title: "Verify Identity" }} />
      <Stack.Screen name="LinkBank" component={LinkBank} options={{ title: "Link Bank" }} />
      <Stack.Screen name="SelectBankAccount" component={SelectBankAccount} options={{ title: "Select Bank Account" }} />
      <Stack.Screen name="Archived" component={Archived} options={{ title: "Archived" }} />
      <Stack.Screen name="NewIouScreen" component={NewIouScreen} options={{ headerShown: false }} />
    </Stack.Navigator>
  );
}

export default function Routes() {
  const [ready, setReady] = useState(false);
  const [splashDone, setSplashDone] = useState(false);
  const [gate, setGate] = useState<GateState>("auth");
  const { isDark } = useAppTheme();

  // gateRef mirrors gate so the onAuthStateChange closure (captured once on
  // mount) can read the current gate without a stale closure.
  const gateRef = React.useRef<GateState>("auth");

  // Tracks the user whose gate evaluation is authoritative. Results from a
  // previous user's in-flight query are discarded when a new sign-in starts.
  const expectedUserIdRef = React.useRef<string | null>(null);

  function applyGate(newGate: GateState) {
    gateRef.current = newGate;
    setGate(newGate);
  }

  useEffect(() => {
    let isMounted = true;

    async function refreshGateForUser(userId: string) {
      expectedUserIdRef.current = userId;
      console.log("[routes] refreshGateForUser start", { userId_suffix: userId.slice(-6) });
      try {
        const withIdentityRes = await supabase
          .from("profiles")
          .select("phone_verified, identity_status")
          .eq("id", userId)
          .single();

        if (!isMounted || expectedUserIdRef.current !== userId) return;

        let profile: ProfileGateRow | null = null;

        if (!withIdentityRes.error && withIdentityRes.data) {
          profile = withIdentityRes.data as ProfileGateRow;
        } else {
          const fallbackRes = await supabase
            .from("profiles")
            .select("phone_verified")
            .eq("id", userId)
            .single();

          if (!isMounted || expectedUserIdRef.current !== userId) return;

          if (!fallbackRes.error && fallbackRes.data) {
            profile = fallbackRes.data as ProfileGateRow;
          }
        }

        console.log("[routes] profile loaded", {
          has_profile: profile !== null,
          phone_verified: profile?.phone_verified,
          identity_status: profile?.identity_status,
        });

        if (!isMounted || expectedUserIdRef.current !== userId) return;

        if (profile === null) {
          console.log("[routes] setting gate phone — profile missing");
          applyGate("phone");
          return;
        }

        if (profile.phone_verified !== true) {
          console.log("[routes] setting gate phone — phone_verified:", profile.phone_verified);
          applyGate("phone");
          return;
        }

        const normalizedIdentity = normalizeIdentityStatus(profile.identity_status);

        if (normalizedIdentity !== "verified") {
          console.log("[routes] setting gate identity, status:", normalizedIdentity);
          applyGate("identity");
          return;
        }

        console.log("[routes] setting gate app");
        applyGate("app");
      } catch (e) {
        console.log("[routes] refreshGateForUser error", e);
        if (isMounted && expectedUserIdRef.current === userId) applyGate("phone");
      } finally {
        console.log("[routes] refreshGateForUser done");
        if (isMounted && expectedUserIdRef.current === userId) setReady(true);
      }
    }

    async function loadGateFromSession() {
      try {
        const {
          data: { session },
        } = await supabase.auth.getSession();

        if (!isMounted) return;

        if (!session?.user) {
          applyGate("auth");
          setReady(true);
          return;
        }

        await refreshGateForUser(session.user.id);
      } catch {
        if (!isMounted) return;
        applyGate("auth");
        setReady(true);
      }
    }

    void loadGateFromSession();

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      console.log("[routes] auth state changed", _event, !!session?.user);

      // TOKEN_REFRESHED during active app use does not change user identity —
      // skip to avoid remounting the navigator every hour.
      // During onboarding ("phone" / "identity"), allow re-evaluation so that
      // refreshSession() after phone or identity verification advances the gate.
      if (_event === "TOKEN_REFRESHED" && gateRef.current === "app") return;

      setReady(false);

      setTimeout(() => {
        if (!isMounted) return;

        if (!session?.user) {
          expectedUserIdRef.current = null;
          applyGate("auth");
          setReady(true);
          return;
        }

        void refreshGateForUser(session.user.id);
      }, 0);
    });

    return () => {
      isMounted = false;
      subscription?.unsubscribe();
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (!splashDone) {
    return <SplashScreen onDone={() => setSplashDone(true)} />;
  }

  if (!ready) {
    return (
      <View style={{ flex: 1, justifyContent: "center", alignItems: "center", backgroundColor: isDark ? '#000000' : '#fff' }}>
        <ActivityIndicator color={BRAND} />
      </View>
    );
  }

  const authScreenOptions = {
    headerStyle: { backgroundColor: isDark ? '#000000' : BRAND },
    headerTintColor: "#fff",
    contentStyle: { backgroundColor: isDark ? '#000000' : '#fff' },
    // Auth screens with visible headers (dark green in light / black in dark)
    // both need light icons. The headerless Auth/Welcome screen overrides this
    // per-screen via navigation.setOptions in useLayoutEffect.
    statusBarStyle: 'light' as const,
  };

  const navTheme = isDark
    ? { ...DarkTheme, colors: { ...DarkTheme.colors, background: '#000000', card: '#000000' } }
    : { ...DefaultTheme, colors: { ...DefaultTheme.colors, background: '#F5F7F9', card: '#FFFFFF' } };

  return (
    <NavigationContainer theme={navTheme}>
      {gate === "auth" ? (
        <Stack.Navigator screenOptions={authScreenOptions}>
          <Stack.Screen
            name="Auth"
            component={Auth}
            options={{ headerShown: false }}
          />
        </Stack.Navigator>
      ) : gate === "phone" ? (
        <Stack.Navigator screenOptions={authScreenOptions}>
          <Stack.Screen
            name="VerifyPhone"
            component={VerifyPhone}
            options={{ title: "Verify Phone", headerBackVisible: false }}
          />
          <Stack.Screen
            name="Profile"
            component={Profile}
            options={{ title: "Profile" }}
          />
        </Stack.Navigator>
      ) : gate === "identity" ? (
        <Stack.Navigator screenOptions={authScreenOptions}>
          <Stack.Screen
            name="VerifyIdentity"
            component={VerifyIdentity}
            options={{ title: "Verify Identity", headerBackVisible: false }}
          />
          <Stack.Screen
            name="LinkBank"
            component={LinkBank}
            options={{ title: "Link Bank" }}
          />
          <Stack.Screen
            name="SelectBankAccount"
            component={SelectBankAccount}
            options={{ title: "Select Bank Account" }}
          />
          <Stack.Screen
            name="Profile"
            component={Profile}
            options={{ title: "Profile" }}
          />
          <Stack.Screen
            name="VerifyPhone"
            component={VerifyPhone}
            options={{ title: "Verify Phone" }}
          />
        </Stack.Navigator>
      ) : (
        <AppTabs />
      )}
    </NavigationContainer>
  );
}

const ts = StyleSheet.create({
  tabBar: {
    position: "absolute",
    left: 16,
    right: 16,
    height: 64,
    backgroundColor: "#fff",
    borderRadius: 32,
    borderTopWidth: 0,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.08,
    shadowRadius: 8,
    elevation: 8,
    paddingBottom: 0,
    paddingTop: 0,
  },
  iconWrap: {
    alignItems: "center",
    justifyContent: "center",
    width: 44,
    height: 36,
    borderRadius: 18,
  },
  // Invisible center gap: gives the two tab pairs room to breathe around the FAB.
  fabGap: {
    width: 80,
  },
  // bottom is injected dynamically from dockBottom + 4 so the FAB center
  // aligns with the dock's vertical midpoint on every device.
  fabContainer: {
    position: "absolute",
    left: 0,
    right: 0,
    alignItems: "center",
    zIndex: 99,
  },
  fab: {
    width: 54,
    height: 54,
    borderRadius: 27,
    backgroundColor: "#1B5E20",
    alignItems: "center",
    justifyContent: "center",
    shadowColor: "#000",
    shadowOpacity: 0.12,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 2 },
    elevation: 8,
  },
});
