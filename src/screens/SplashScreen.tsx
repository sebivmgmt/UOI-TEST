import React, { useEffect } from 'react';
import { Image, View, StyleSheet } from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
  withSequence,
  withDelay,
  withRepeat,
  runOnJS,
  Easing,
} from 'react-native-reanimated';

const LOGO_W = 240;
const LOGO_H = 80;
const O_SIZE = 110;

export default function SplashScreen({ onDone }: { onDone: () => void }) {
  const opacity = useSharedValue(0);
  const scale = useSharedValue(0.82);
  const rotation = useSharedValue(0);

  const containerStyle = useAnimatedStyle(() => ({
    opacity: opacity.value,
    transform: [{ scale: scale.value }],
  }));

  const spinStyle = useAnimatedStyle(() => ({
    transform: [{ rotate: `${rotation.value}deg` }],
  }));

  useEffect(() => {
    // 7s spinning → 7s paused → loop
    rotation.value = withRepeat(
      withSequence(
        withTiming(360, { duration: 7000, easing: Easing.linear }),
        withTiming(360, { duration: 7000 }), // hold — no visual change, acts as pause
      ),
      -1,
      false
    );

    scale.value = withTiming(1, { duration: 500, easing: Easing.out(Easing.back(1.3)) });
    opacity.value = withSequence(
      withTiming(1, { duration: 400 }),
      withDelay(900, withTiming(0, { duration: 350 }, (finished) => {
        if (finished) runOnJS(onDone)();
      }))
    );
  }, []);

  return (
    <View style={s.container}>
      <Animated.View style={[s.logoWrap, containerStyle]}>
        <Image
          source={require('../../assets/iou-iu.png')}
          style={s.iu}
          resizeMode="contain"
        />
        <Animated.Image
          source={require('../../assets/iou-o.png')}
          style={[s.o, spinStyle]}
          resizeMode="contain"
        />
      </Animated.View>
    </View>
  );
}

const s = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  logoWrap: {
    width: LOGO_W,
    height: LOGO_H,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iu: {
    width: LOGO_W,
    height: LOGO_H,
    position: 'absolute',
  },
  o: {
    width: O_SIZE,
    height: O_SIZE,
    position: 'absolute',
  },
});
