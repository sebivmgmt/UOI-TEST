import React, { useEffect } from 'react';
import { Image } from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withRepeat,
  withTiming,
  withSequence,
  withDelay,
  Easing,
} from 'react-native-reanimated';

const BRAND = '#1B5E20';

type Props = {
  size?: number;
  animate?: 'none' | 'pulse' | 'fade-in';
};

// Full IOU wordmark — save assets/iou-logo.png with the handwritten I·↻·U design
export default function IouLogo({ size = 160, animate = 'none' }: Props) {
  const scale = useSharedValue(animate === 'pulse' ? 0.85 : 1);
  const opacity = useSharedValue(animate === 'fade-in' ? 0 : 1);

  useEffect(() => {
    if (animate === 'pulse') {
      scale.value = withRepeat(
        withSequence(
          withTiming(1, { duration: 500, easing: Easing.out(Easing.ease) }),
          withDelay(1800, withTiming(0.85, { duration: 500, easing: Easing.in(Easing.ease) }))
        ),
        -1,
        false
      );
    } else if (animate === 'fade-in') {
      opacity.value = withTiming(1, { duration: 600, easing: Easing.out(Easing.ease) });
    }
  }, []);

  const animStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
    opacity: opacity.value,
  }));

  const aspectRatio = 3; // IOU wordmark is roughly 3:1 wide
  const w = size * aspectRatio;
  const h = size;

  return (
    <Animated.View style={animStyle}>
      <Image
        source={require('../../assets/iou-logo.png')}
        style={{ width: w, height: h }}
        resizeMode="contain"
      />
    </Animated.View>
  );
}
