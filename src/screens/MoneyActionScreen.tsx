import React from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Dimensions,
  StatusBar,
} from "react-native";

const BRAND = "#1B5E20";
const BLUE = "#1565C0";
const AMBER = "#E65100";
const GRAY = "#9CA3AF";
const { width } = Dimensions.get("window");

type ActionId = "lend" | "borrow" | "split" | "rent";

type Action = {
  id: ActionId;
  title: string;
  subtitle: string;
  color: string;
  bg: string;
  disabled?: boolean;
};

const ACTIONS: Action[] = [
  {
    id: "lend",
    title: "Lend",
    subtitle: "Create an IOU\nas the lender",
    color: BRAND,
    bg: "#E8F5E9",
  },
  {
    id: "borrow",
    title: "Borrow",
    subtitle: "Request money\nas the borrower",
    color: BLUE,
    bg: "#E3F2FD",
  },
  {
    id: "split",
    title: "Split",
    subtitle: "Scan & split\na receipt",
    color: AMBER,
    bg: "#FFF3E0",
  },
  {
    id: "rent",
    title: "Rent",
    subtitle: "Coming\nSoon",
    color: GRAY,
    bg: "#F3F4F6",
    disabled: true,
  },
];

// ─── Icon components ──────────────────────────────────────────────────────────

function LendIcon({ color }: { color: string }) {
  return (
    <View style={{ alignItems: "center", gap: 2 }}>
      <View style={{ width: 0, height: 0, borderLeftWidth: 9, borderRightWidth: 9, borderBottomWidth: 13, borderLeftColor: "transparent", borderRightColor: "transparent", borderBottomColor: color }} />
      <View style={{ width: 5, height: 9, backgroundColor: color, borderRadius: 2 }} />
    </View>
  );
}

function BorrowIcon({ color }: { color: string }) {
  return (
    <View style={{ alignItems: "center", gap: 2 }}>
      <View style={{ width: 5, height: 9, backgroundColor: color, borderRadius: 2 }} />
      <View style={{ width: 0, height: 0, borderLeftWidth: 9, borderRightWidth: 9, borderTopWidth: 13, borderLeftColor: "transparent", borderRightColor: "transparent", borderTopColor: color }} />
    </View>
  );
}

function SplitIcon({ color }: { color: string }) {
  const sw = 3;
  return (
    <View style={{ width: 32, height: 26 }}>
      {/* Stem */}
      <View style={{ position: "absolute", left: 14.5, top: 0, width: sw, height: 10, backgroundColor: color, borderRadius: 1.5 }} />
      {/* Horizontal connector */}
      <View style={{ position: "absolute", left: 4, top: 10, width: 24, height: sw, backgroundColor: color, borderRadius: 1.5 }} />
      {/* Left branch */}
      <View style={{ position: "absolute", left: 4, top: 10, width: sw, height: 13, backgroundColor: color, borderRadius: 1.5 }} />
      {/* Center branch */}
      <View style={{ position: "absolute", left: 14.5, top: 10, width: sw, height: 13, backgroundColor: color, borderRadius: 1.5 }} />
      {/* Right branch */}
      <View style={{ position: "absolute", right: 4, top: 10, width: sw, height: 13, backgroundColor: color, borderRadius: 1.5 }} />
    </View>
  );
}

function RentIcon({ color }: { color: string }) {
  return (
    <View style={{ alignItems: "center" }}>
      <View style={{ width: 0, height: 0, borderLeftWidth: 14, borderRightWidth: 14, borderBottomWidth: 12, borderLeftColor: "transparent", borderRightColor: "transparent", borderBottomColor: color }} />
      <View style={{ width: 22, height: 13, backgroundColor: color, borderBottomLeftRadius: 3, borderBottomRightRadius: 3, alignItems: "center", justifyContent: "flex-end", paddingBottom: 2 }}>
        <View style={{ width: 6, height: 7, backgroundColor: "#fff", borderRadius: 1.5 }} />
      </View>
    </View>
  );
}

function ActionIcon({ id, color }: { id: ActionId; color: string }) {
  if (id === "lend") return <LendIcon color={color} />;
  if (id === "borrow") return <BorrowIcon color={color} />;
  if (id === "split") return <SplitIcon color={color} />;
  return <RentIcon color={color} />;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function MoneyActionScreen({ navigation }: any) {
  const cardWidth = (width - 48) / 2;

  const handleAction = (action: Action) => {
    if (action.disabled) return;
    if (action.id === "lend") {
      navigation.replace("NewLoan", { mode: "lend" });
    } else if (action.id === "borrow") {
      navigation.replace("NewLoan", { mode: "borrow" });
    } else if (action.id === "split") {
      navigation.replace("SplitReceipt");
    }
  };

  return (
    <View style={s.screen}>
      <StatusBar barStyle="dark-content" />

      <View style={s.handle} />

      <Text style={s.title}>What would you like to do?</Text>
      <Text style={s.subtitle}>Choose a money action to get started</Text>

      <View style={s.grid}>
        {ACTIONS.map((action) => (
          <TouchableOpacity
            key={action.id}
            style={[
              s.card,
              { width: cardWidth },
              action.disabled && s.cardDisabled,
            ]}
            onPress={() => handleAction(action)}
            activeOpacity={action.disabled ? 1 : 0.78}
          >
            {/* Colored icon zone */}
            <View style={[s.iconZone, { backgroundColor: action.bg }]}>
              <ActionIcon id={action.id} color={action.color} />
              {action.disabled && (
                <View style={s.soonBadge}>
                  <Text style={s.soonText}>Soon</Text>
                </View>
              )}
            </View>

            {/* Text */}
            <View style={s.cardBody}>
              <Text style={[s.cardTitle, { color: action.disabled ? GRAY : "#111827" }]}>
                {action.title}
              </Text>
              <Text style={s.cardSub}>{action.subtitle}</Text>
            </View>

            {/* Bottom accent stripe */}
            <View style={[s.accentStripe, { backgroundColor: action.disabled ? "#E5E7EB" : action.color }]} />
          </TouchableOpacity>
        ))}
      </View>

      {/* This is a controlled dev-only entry point for the guided New IOU flow.
          Do not expose in production until legal documents, APR cap constant,
          and acceptance persistence are complete.
          __DEV__ is always false in production/release builds. */}
      {__DEV__ && (
        <TouchableOpacity
          style={s.devTestBtn}
          onPress={() => navigation.replace("NewIouScreen")}
          activeOpacity={0.75}
        >
          <Text style={s.devTestBtnText}>Dev: New IOU Guided Flow</Text>
        </TouchableOpacity>
      )}

      <TouchableOpacity
        style={s.cancelBtn}
        onPress={() => navigation.goBack()}
        activeOpacity={0.7}
      >
        <Text style={s.cancelText}>Cancel</Text>
      </TouchableOpacity>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: "#F5F7F9",
    paddingHorizontal: 16,
    paddingTop: 16,
  },
  handle: {
    width: 36,
    height: 4,
    backgroundColor: "#D1D5DB",
    borderRadius: 999,
    alignSelf: "center",
    marginBottom: 20,
  },
  title: {
    fontSize: 22,
    fontWeight: "900",
    color: "#111827",
    textAlign: "center",
    marginBottom: 6,
  },
  subtitle: {
    fontSize: 14,
    fontWeight: "600",
    color: "#6B7280",
    textAlign: "center",
    marginBottom: 28,
  },
  grid: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 16,
    justifyContent: "center",
  },
  card: {
    backgroundColor: "#fff",
    borderRadius: 20,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    overflow: "hidden",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 3 },
    shadowOpacity: 0.07,
    shadowRadius: 10,
    elevation: 4,
  },
  cardDisabled: {
    opacity: 0.6,
  },
  iconZone: {
    height: 108,
    alignItems: "center",
    justifyContent: "center",
  },
  soonBadge: {
    position: "absolute",
    top: 10,
    right: 10,
    backgroundColor: "#6B7280",
    borderRadius: 999,
    paddingHorizontal: 7,
    paddingVertical: 3,
  },
  soonText: {
    fontSize: 9,
    fontWeight: "900",
    color: "#fff",
    letterSpacing: 0.3,
    textTransform: "uppercase",
  },
  cardBody: {
    paddingHorizontal: 14,
    paddingTop: 12,
    paddingBottom: 14,
  },
  cardTitle: {
    fontSize: 18,
    fontWeight: "900",
    marginBottom: 4,
  },
  cardSub: {
    fontSize: 12,
    fontWeight: "600",
    color: "#6B7280",
    lineHeight: 18,
  },
  accentStripe: {
    height: 3,
  },
  cancelBtn: {
    marginTop: 28,
    alignItems: "center",
    paddingVertical: 14,
  },
  cancelText: {
    fontSize: 16,
    fontWeight: "700",
    color: "#6B7280",
  },
  devTestBtn: {
    marginTop: 16,
    marginHorizontal: 8,
    paddingVertical: 10,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "#D1D5DB",
    alignItems: "center",
    backgroundColor: "#F9FAFB",
  },
  devTestBtnText: {
    fontSize: 13,
    fontWeight: "700",
    color: "#6B7280",
  },
});
