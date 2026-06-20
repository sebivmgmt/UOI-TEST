// src/dev/DevOverlay.tsx
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { View, Text, TouchableOpacity, PanResponder, GestureResponderEvent } from 'react-native';

type Check = { label: string; pass: boolean; note?: string };
let latest: { screen: string; checks: Check[] } = { screen: 'Unknown', checks: [] };

export function setDevState(screen: string, checks: Check[]) {
  latest = { screen, checks };
}

export default function DevOverlay() {
  const [visible, setVisible] = useState(false);
  const [snapshot, setSnapshot] = useState(latest);
  const taps = useRef<{count: number; last: number; fingers: number}>({count:0,last:0,fingers:0});

  const onTouch = useCallback((e: GestureResponderEvent) => {
    const now = Date.now();
    const fingers = e.nativeEvent.touches.length;
    if (fingers >= 3) {
      if (now - taps.current.last < 350) taps.current.count += 1; else taps.current.count = 1;
      taps.current.last = now; taps.current.fingers = fingers;
      if (taps.current.count >= 2) { // 3-finger double tap
        setSnapshot(latest);
        setVisible(v => !v);
        taps.current.count = 0;
      }
    }
  }, []);

  useEffect(() => {
    const id = setInterval(() => setSnapshot(latest), 800);
    return () => clearInterval(id);
  }, []);

  if (!visible) return (
    <View
      onTouchStart={onTouch}
      style={{ position:'absolute', top:0, left:0, right:0, bottom:0, backgroundColor:'transparent', zIndex:9999 }}
      pointerEvents="box-none"
    />
  );

  const ok = snapshot.checks.filter(c=>c.pass).length;
  const total = snapshot.checks.length;

  return (
    <View
      onTouchStart={onTouch}
      style={{ position:'absolute', top:12, right:12, left:12, padding:12, borderRadius:12, zIndex:9999,
               backgroundColor:'rgba(0,0,0,0.85)'}}>
      <Text style={{ color:'#fff', fontWeight:'800', fontSize:16 }}>
        {snapshot.screen} • Checks {ok}/{total}
      </Text>
      {snapshot.checks.map((c, i)=>(
        <View key={i} style={{ marginTop:6, flexDirection:'row', alignItems:'center' }}>
          <Text style={{ width:18, color: c.pass ? '#7CFC90' : '#FF6B6B' }}>
            {c.pass ? '✓' : '✗'}
          </Text>
          <Text style={{ color:'#fff' }}>{c.label}{c.note ? ` — ${c.note}` : ''}</Text>
        </View>
      ))}
      <TouchableOpacity onPress={()=>setVisible(false)} style={{ marginTop:10, alignSelf:'flex-end' }}>
        <Text style={{ color:'#9ad' }}>Hide</Text>
      </TouchableOpacity>
    </View>
  );
}