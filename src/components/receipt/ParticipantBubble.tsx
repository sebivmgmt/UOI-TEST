import React from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import SebivAvatar from '../SebivAvatar';
import { Participant } from '../../context/receiptSplitContext';

const BRAND = '#1B5E20';

type Props = {
  participant: Participant;
  size?: number;
  selected?: boolean;
  onPress?: () => void;
  showName?: boolean;
};

export default function ParticipantBubble({
  participant,
  size = 44,
  selected = false,
  onPress,
  showName = false,
}: Props) {
  return (
    <TouchableOpacity
      onPress={onPress}
      activeOpacity={0.75}
      style={styles.wrap}
      disabled={!onPress}
    >
      <View
        style={[
          styles.ring,
          {
            width: size + 6,
            height: size + 6,
            borderRadius: (size + 6) / 2,
            borderColor: selected ? BRAND : 'transparent',
            borderWidth: selected ? 2.5 : 0,
          },
        ]}
      >
        <SebivAvatar uri={participant.avatar_url} size={size} />
        {selected && (
          <View style={[styles.checkBadge, { right: -2, bottom: -2 }]}>
            <View style={styles.checkInner} />
          </View>
        )}
      </View>
      {showName && (
        <Text style={[styles.nameLabel, { maxWidth: size + 12 }]} numberOfLines={1}>
          {participant.name.split(' ')[0]}
        </Text>
      )}
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  wrap: {
    alignItems: 'center',
    gap: 4,
  },
  ring: {
    alignItems: 'center',
    justifyContent: 'center',
    position: 'relative',
  },
  checkBadge: {
    position: 'absolute',
    width: 16,
    height: 16,
    borderRadius: 8,
    backgroundColor: BRAND,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderColor: '#fff',
  },
  checkInner: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: '#fff',
  },
  nameLabel: {
    fontSize: 11,
    fontWeight: '700',
    color: '#374151',
    textAlign: 'center',
  },
});
