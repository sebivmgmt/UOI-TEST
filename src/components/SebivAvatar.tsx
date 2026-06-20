import React from "react";
import { View, Image } from "react-native";

const BRAND = "#1B5E20";
const BRAND_LIGHT = "#E8F5E9";

type Props = {
  uri?: string | null;
  size?: number;
  style?: object;
};

function SebivIcon({ size, color }: { size: number; color: string }) {
  const sw = Math.max(1.5, size / 9);
  const r = sw / 2;
  const cx = size / 2;
  const cy = size / 2;
  const hdx = size * 0.31; // horizontal half-span
  const hdy = size * 0.36; // vertical half-span (slightly taller than wide)
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
  };
  return (
    <View style={{ width: size, height: size }}>
      {/* Horizontal top bar */}
      <View style={{ position: "absolute", left: cx - hdx, top: cy - hdy - r, width: dx, height: sw, backgroundColor: color, borderRadius: r }} />
      {/* \ diagonal */}
      <View style={[diagBase, { transform: [{ rotate: `${deg}deg` }] }]} />
      {/* / diagonal */}
      <View style={[diagBase, { transform: [{ rotate: `${-deg}deg` }] }]} />
    </View>
  );
}

export default function SebivAvatar({ uri, size = 46, style }: Props) {
  if (uri) {
    return (
      <Image
        source={{ uri }}
        style={[{ width: size, height: size, borderRadius: size / 2 }, style]}
      />
    );
  }
  return (
    <View
      style={[
        {
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: BRAND_LIGHT,
          alignItems: "center",
          justifyContent: "center",
        },
        style,
      ]}
    >
      <SebivIcon size={size * 0.52} color={BRAND} />
    </View>
  );
}
