import React from "react";
import { View, TouchableOpacity, StyleSheet } from "react-native";

const BRAND = "#77B777";
const INACTIVE = "#E5E7EB";

type Props = {
  total: number;
  current: number;
  onStepPress?: (step: number) => void;
};

function Marker({
  index,
  current,
  onPress,
}: {
  index: number;
  current: number;
  onPress?: () => void;
}) {
  const done = index < current;
  const active = index === current;

  const shape = (
    <View
      style={[
        s.marker,
        active && s.markerActive,
        done && s.markerDone,
        !active && !done && s.markerInactive,
      ]}
    >
      {done && <View style={s.innerDot} />}
    </View>
  );

  if (done && onPress) {
    return (
      <TouchableOpacity onPress={onPress} activeOpacity={0.7}>
        {shape}
      </TouchableOpacity>
    );
  }

  return shape;
}

export default function IouStepProgress({ total, current, onStepPress }: Props) {
  return (
    <View style={s.row}>
      {Array.from({ length: total }).map((_, i) => (
        <React.Fragment key={i}>
          <Marker
            index={i}
            current={current}
            onPress={onStepPress ? () => onStepPress(i) : undefined}
          />
          {i < total - 1 && (
            <View style={[s.line, i < current && s.lineDone]} />
          )}
        </React.Fragment>
      ))}
    </View>
  );
}

const s = StyleSheet.create({
  row: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 24,
    paddingVertical: 4,
  },

  // Angular parallelogram — skewX gives the "7"-inspired lean
  marker: {
    width: 12,
    height: 18,
    borderRadius: 2,
    transform: [{ skewX: "-10deg" }],
    alignItems: "center",
    justifyContent: "center",
  },

  markerInactive: {
    backgroundColor: INACTIVE,
  },

  markerActive: {
    backgroundColor: BRAND,
    width: 16,
    height: 22,
  },

  markerDone: {
    backgroundColor: BRAND,
  },

  // Counter-skew so the inner dot stays visually square
  innerDot: {
    width: 4,
    height: 4,
    borderRadius: 2,
    backgroundColor: "#fff",
    transform: [{ skewX: "10deg" }],
  },

  line: {
    flex: 1,
    height: 2,
    backgroundColor: INACTIVE,
    marginHorizontal: 4,
  },

  lineDone: {
    backgroundColor: BRAND,
  },
});
