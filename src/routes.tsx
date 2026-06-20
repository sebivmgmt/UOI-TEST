import React, { useEffect, useState } from "react";
import { ActivityIndicator, Image, TouchableOpacity, View, StyleSheet } from "react-native";
import { NavigationContainer, useNavigation } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
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
  NewIouScreen: undefined;
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

// Pure-View tab icons — no native SVG required.
function HomeTabIcon({ color }: { color: string }) {
  return (
    <View style={{ alignItems: "center", justifyContent: "flex-end", height: 22 }}>
      <View style={{ width: 0, height: 0, borderLeftWidth: 11, borderRightWidth: 11, borderBottomWidth: 9, borderLeftColor: "transparent", borderRightColor: "transparent", borderBottomColor: color }} />
      <View style={{ width: 15, height: 10, backgroundColor: color, borderBottomLeftRadius: 2, borderBottomRightRadius: 2 }} />
    </View>
  );
}


function PeopleTabIcon({ color }: { color: string }) {
  // Two SEBIV figures: back-left (smaller, dimmed) + front-right (primary)
  const figure = (
    cx: number, cy: number,
    hdx: number, hdy: number,
    sw: number, opacity: number
  ) => {
    const r = sw / 2;
    const dx = hdx * 2;
    const dy = hdy * 2;
    const len = Math.sqrt(dx * dx + dy * dy);
    const deg = Math.atan2(dy, dx) * (180 / Math.PI);
    const diagBase = {
      position: "absolute" as const,
      left: cx - len / 2,
      top: cy - r,
      width: len,
      height: sw,
      backgroundColor: color,
      borderRadius: r,
      opacity,
    };
    return (
      <>
        {/* Horizontal bar */}
        <View style={{ position: "absolute", left: cx - hdx, top: cy - hdy - r, width: dx, height: sw, backgroundColor: color, borderRadius: r, opacity }} />
        {/* \ diagonal */}
        <View style={[diagBase, { transform: [{ rotate: `${deg}deg` }] }]} />
        {/* / diagonal */}
        <View style={[diagBase, { transform: [{ rotate: `${-deg}deg` }] }]} />
      </>
    );
  };

  return (
    <View style={{ width: 28, height: 22 }}>
      {/* Back figure: smaller, offset left, dimmed */}
      {figure(8, 12, 4, 5, 1.8, 0.5)}
      {/* Front figure: full weight, offset right */}
      {figure(17, 11, 5, 7, 2.3, 1.0)}
    </View>
  );
}

// Shield shape: rounded-top rectangle + downward triangle point.
function TrustTabIcon({ color }: { color: string }) {
  return (
    <View style={{ alignItems: "center", justifyContent: "flex-start", height: 22, paddingTop: 1 }}>
      {/* Shield body — rounded on top, flat on bottom */}
      <View style={{
        width: 16,
        height: 13,
        backgroundColor: color,
        borderTopLeftRadius: 8,
        borderTopRightRadius: 8,
      }} />
      {/* Shield point — downward triangle */}
      <View style={{
        width: 0,
        height: 0,
        borderLeftWidth: 8,
        borderRightWidth: 8,
        borderTopWidth: 7,
        borderLeftColor: "transparent",
        borderRightColor: "transparent",
        borderTopColor: color,
      }} />
    </View>
  );
}

function ProfileTabIcon({ color }: { color: string }) {
  // SEBIV logo: horizontal bar + two crossing diagonals
  const sw = 2.5;
  const r = sw / 2;
  const x1 = 4, x2 = 18, y1 = 3, y2 = 19;
  const cx = (x1 + x2) / 2;
  const cy = (y1 + y2) / 2;
  const dx = x2 - x1;
  const dy = y2 - y1;
  const len = Math.sqrt(dx * dx + dy * dy);
  const deg = Math.atan2(dy, dx) * (180 / Math.PI);
  const diagBase = {
    position: "absolute" as const,
    left: cx - len / 2,
    top: cy - r,
    width: len,
    height: sw,
    backgroundColor: color,
    borderRadius: r,
  };
  return (
    <View style={{ width: 22, height: 22 }}>
      {/* Horizontal top bar */}
      <View style={{ position: "absolute", left: x1, top: y1 - r, width: dx, height: sw, backgroundColor: color, borderRadius: r }} />
      {/* Left-to-right diagonal (\) */}
      <View style={[diagBase, { transform: [{ rotate: `${deg}deg` }] }]} />
      {/* Right-to-left diagonal (/) */}
      <View style={[diagBase, { transform: [{ rotate: `${-deg}deg` }] }]} />
    </View>
  );
}

// FAB overlay: rendered outside Tab.Navigator so it has its own independent
// z-index, elevation, and touch zone unconstrained by the tab bar bounds.
function NewIouFab() {
  const navigation = useNavigation<any>();
  return (
    <View style={ts.fabContainer} pointerEvents="box-none">
      <TouchableOpacity
        style={ts.fab}
        onPress={() => navigation.navigate("HomeTab", { screen: "MoneyAction" })}
        activeOpacity={0.78}
        hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
      >
        <Image
          source={require('../assets/iou-o-fab-clean.png')}
          style={ts.fabIcon}
          resizeMode="contain"
        />
      </TouchableOpacity>
    </View>
  );
}

// App tab navigator wrapping common screens.
// Tab order: Home | People | [FAB] | Trust | Profile
// The pending IOU badge lives on Home (moved from the old IOUs tab).
function AppTabs() {
  const pendingCount = usePendingIouCount();
  return (
    <View style={{ flex: 1 }}>
      <Tab.Navigator
        screenOptions={{
          headerShown: false,
          tabBarActiveTintColor: "#77B777",
          tabBarInactiveTintColor: "#9E9E9E",
          tabBarShowLabel: false,
          tabBarStyle: ts.tabBar,
        }}
      >
        <Tab.Screen
          name="HomeTab"
          component={HomeStack}
          options={{
            tabBarBadge: pendingCount > 0 ? pendingCount : undefined,
            tabBarIcon: ({ color, focused }) => (
              <View style={[ts.iconWrap, focused && ts.iconWrapActive]}>
                <HomeTabIcon color={color} />
              </View>
            ),
          }}
        />
        <Tab.Screen
          name="PeopleTab"
          component={PeopleStack}
          options={{
            tabBarIcon: ({ color, focused }) => (
              <View style={[ts.iconWrap, focused && ts.iconWrapActive]}>
                <PeopleTabIcon color={color} />
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
            tabBarIcon: ({ color, focused }) => (
              <View style={[ts.iconWrap, focused && ts.iconWrapActive]}>
                <TrustTabIcon color={color} />
              </View>
            ),
          }}
        />
        <Tab.Screen
          name="Profile"
          component={ProfileStack}
          options={{
            tabBarIcon: ({ color, focused }) => (
              <View style={[ts.iconWrap, focused && ts.iconWrapActive]}>
                <ProfileTabIcon color={color} />
              </View>
            ),
          }}
        />
      </Tab.Navigator>
      <NewIouFab />
    </View>
  );
}

// Home stack — includes IOUsList so IOUs remain reachable after removing the IOUs tab.
function HomeStack() {
  const screenOptions = {
    headerStyle: { backgroundColor: BRAND },
    headerTintColor: "#fff",
    contentStyle: { backgroundColor: "#F5F7F9", paddingBottom: 92 },
  } as const;

  return (
    <ReceiptSplitProvider>
      <Stack.Navigator screenOptions={screenOptions}>
        <Stack.Screen name="Home" component={Home} options={{ title: "Home" }} />
        <Stack.Screen name="IOUsList" component={IousListScreen} options={{ title: "My IOUs" }} />
        <Stack.Screen name="Inbox" component={Inbox} options={{ title: "IOU Inbox" }} />
        <Stack.Screen name="Profile" component={Profile} options={{ title: "Profile" }} />
        <Stack.Screen name="Archived" component={Archived} options={{ title: "Archived" }} />
        <Stack.Screen name="SearchUsers" component={SearchUsersScreen} options={{ title: "Search Users" }} />
        <Stack.Screen name="Person" component={PersonScreen} options={{ title: "Person" }} />
        <Stack.Screen name="NewLoan" component={NewLoan} options={{ title: "New IOU" }} />
        <Stack.Screen name="NewIouScreen" component={NewIouScreen} options={{ title: "New IOU (Guided)", headerShown: false }} />
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
      </Stack.Navigator>
    </ReceiptSplitProvider>
  );
}

// Trust stack — root of the Trust bottom tab.
// Step 2: promoted to a real tab. IOUsList moved to HomeStack to free this slot.
function TrustStack() {
  const screenOptions = {
    headerStyle: { backgroundColor: BRAND },
    headerTintColor: "#fff",
    contentStyle: { backgroundColor: "#F5F7F9", paddingBottom: 92 },
  } as const;

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
  const screenOptions = {
    headerStyle: { backgroundColor: BRAND },
    headerTintColor: "#fff",
    contentStyle: { backgroundColor: "#F5F7F9", paddingBottom: 92 },
  } as const;

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
  const screenOptions = {
    headerStyle: { backgroundColor: BRAND },
    headerTintColor: "#fff",
    contentStyle: { backgroundColor: "#F5F7F9", paddingBottom: 92 },
  } as const;

  return (
    <Stack.Navigator screenOptions={screenOptions}>
      <Stack.Screen name="Profile" component={Profile} options={{ title: "Profile" }} />
      <Stack.Screen name="VerifyPhone" component={VerifyPhone} options={{ title: "Verify Phone" }} />
      <Stack.Screen name="VerifyIdentity" component={VerifyIdentity} options={{ title: "Verify Identity" }} />
      <Stack.Screen name="LinkBank" component={LinkBank} options={{ title: "Link Bank" }} />
      <Stack.Screen name="SelectBankAccount" component={SelectBankAccount} options={{ title: "Select Bank Account" }} />
      <Stack.Screen name="Archived" component={Archived} options={{ title: "Archived" }} />
      {/* Dev-only entry point — NewIouScreen is hidden behind __DEV__ in Profile.tsx.
          Registration required so navigation.navigate("NewIouScreen") works from ProfileStack. */}
      <Stack.Screen name="NewIouScreen" component={NewIouScreen} options={{ headerShown: false }} />
    </Stack.Navigator>
  );
}

export default function Routes() {
  const [ready, setReady] = useState(false);
  const [splashDone, setSplashDone] = useState(false);
  const [gate, setGate] = useState<GateState>("auth");

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
      <View style={{ flex: 1, justifyContent: "center", alignItems: "center" }}>
        <ActivityIndicator color={BRAND} />
      </View>
    );
  }

  const authScreenOptions = {
    headerStyle: { backgroundColor: BRAND },
    headerTintColor: "#fff",
    contentStyle: { backgroundColor: "#fff" },
  } as const;

  return (
    <NavigationContainer>
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
    bottom: 20,
    left: 16,
    right: 16,
    height: 64,
    backgroundColor: "#fff",
    borderRadius: 28,
    borderTopWidth: 0,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.07,
    shadowRadius: 12,
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
  iconWrapActive: {
    backgroundColor: "#E8F5E9",
  },
  // Invisible center gap: gives the two tab pairs room to breathe around the FAB.
  fabGap: {
    width: 80,
  },
  fabContainer: {
    position: "absolute",
    bottom: 42,
    left: 0,
    right: 0,
    alignItems: "center",
    zIndex: 99,
  },
  fab: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: "#fff",
    alignItems: "center",
    justifyContent: "center",
    shadowColor: "#000",
    shadowOpacity: 0.14,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 3 },
    elevation: 10,
  },
  fabIcon: {
    width: 44,
    height: 44,
    tintColor: "#1B5E20",
  },
});
