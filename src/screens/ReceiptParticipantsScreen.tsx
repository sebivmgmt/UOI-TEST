import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { useReceiptSplit, Participant } from '../context/receiptSplitContext';
import ParticipantBubble from '../components/receipt/ParticipantBubble';
import { supabase } from '../supabase';
import { persistParticipants } from '../services/receiptPersistenceService';

const BRAND = '#1B5E20';
const BG = '#F5F7F9';

type Props = { navigation: any };

export default function ReceiptParticipantsScreen({ navigation }: Props) {
  const { draft, participantDbIdMap, setParticipants, setPayerId, setParticipantDbIdMap } = useReceiptSplit();
  const [currentUser, setCurrentUser] = useState<Participant | null>(null);
  const [friends, setFriends] = useState<Participant[]>([]);
  const [loadingFriends, setLoadingFriends] = useState(true);
  const [selectedFriendIds, setSelectedFriendIds] = useState<Set<string>>(new Set());
  const [search, setSearch] = useState('');
  const [persisting, setPersisting] = useState(false);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getUser();
      const user = data.user;
      if (user) {
        const { data: profile } = await supabase
          .from('profiles')
          .select('full_name, avatar_url, email')
          .eq('id', user.id)
          .maybeSingle();

        const me: Participant = {
          id: user.id,
          name: (profile as any)?.full_name || user.email?.split('@')[0] || 'You',
          email: (profile as any)?.email || user.email,
          avatar_url: (profile as any)?.avatar_url ?? null,
          isOwner: true,
        };
        setCurrentUser(me);

        const { data: contacts, error: contactsError } = await supabase.rpc(
          'get_my_iou_contacts'
        );

        if (!contactsError) {
          setFriends(
            ((contacts ?? []) as any[]).map((p) => ({
              id: p.id,
              name: p.public_name || 'User',
              avatar_url: p.avatar_url ?? null,
            }))
          );
        }
      }
      setLoadingFriends(false);
    })();
  }, []);

  const filteredFriends = friends.filter(f =>
    f.name.toLowerCase().includes(search.toLowerCase())
  );

  function toggleFriend(id: string) {
    setSelectedFriendIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  const totalSelected = selectedFriendIds.size + (currentUser ? 1 : 0);
  const canContinue = totalSelected >= 2;

  async function handleContinue() {
    if (!currentUser) return;
    const selected = friends.filter(f => selectedFriendIds.has(f.id));
    const all: Participant[] = [currentUser, ...selected];

    if (draft?.splitId) {
      // Back-navigation guard: skip re-inserting only if the exact same participant set is already persisted.
      const persistedIds = new Set(Object.keys(participantDbIdMap));
      const alreadyPersisted =
        persistedIds.size === all.length && all.every(p => persistedIds.has(p.id));
      if (!alreadyPersisted) {
        setPersisting(true);
        try {
          const { participantDbIdMap: newMap } = await persistParticipants(draft.splitId, all);
          setParticipantDbIdMap(newMap);
        } catch {
          setPersisting(false);
          Alert.alert('Could Not Save', 'Something went wrong. Please try again.');
          return;
        }
        setPersisting(false);
      }
    }

    setParticipants(all);
    setPayerId(currentUser.id);
    navigation.navigate('AssignItems');
  }

  return (
    <View style={{ flex: 1, backgroundColor: BG }}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <View style={styles.card}>
          <Text style={styles.sectionLabel}>You (payer)</Text>
          {currentUser ? (
            <View style={styles.ownerRow}>
              <ParticipantBubble
                participant={currentUser}
                size={52}
                selected
                showName={false}
              />
              <View style={styles.ownerInfo}>
                <Text style={styles.ownerName}>{currentUser.name}</Text>
                <Text style={styles.ownerEmail}>{currentUser.email}</Text>
                <View style={styles.payerBadge}>
                  <Text style={styles.payerBadgeText}>Paying tonight</Text>
                </View>
              </View>
            </View>
          ) : (
            <View style={styles.ownerPlaceholder}>
              <View style={styles.ownerPlaceholderCircle} />
              <View style={styles.ownerPlaceholderLines}>
                <View style={[styles.shimmer, { width: 120 }]} />
                <View style={[styles.shimmer, { width: 80 }]} />
              </View>
            </View>
          )}
        </View>

        <View style={styles.card}>
          <Text style={styles.sectionLabel}>Add Friends</Text>
          <View style={styles.searchWrap}>
            <TextInput
              style={styles.searchInput}
              value={search}
              onChangeText={setSearch}
              placeholder="Search friends..."
              placeholderTextColor="#9CA3AF"
              clearButtonMode="while-editing"
            />
          </View>

          {filteredFriends.map(friend => {
            const isSelected = selectedFriendIds.has(friend.id);
            return (
              <TouchableOpacity
                key={friend.id}
                style={[styles.friendRow, isSelected && styles.friendRowSelected]}
                onPress={() => toggleFriend(friend.id)}
                activeOpacity={0.8}
              >
                <ParticipantBubble
                  participant={friend}
                  size={44}
                  selected={isSelected}
                />
                <View style={styles.friendInfo}>
                  <Text style={styles.friendName}>{friend.name}</Text>
                </View>
                <View style={[styles.selCheckbox, isSelected && styles.selCheckboxActive]}>
                  {isSelected && <View style={styles.selDot} />}
                </View>
              </TouchableOpacity>
            );
          })}

          {loadingFriends && (
            <ActivityIndicator color={BRAND} style={{ marginVertical: 16 }} />
          )}
          {!loadingFriends && filteredFriends.length === 0 && (
            <Text style={styles.noResults}>
              {search.length > 0
                ? `No friends match "${search}"`
                : 'No friends found yet. Create another test account or invite a friend.'}
            </Text>
          )}
        </View>

        {selectedFriendIds.size > 0 && (
          <View style={styles.selectedPreviewCard}>
            <Text style={styles.selectedPreviewLabel}>
              Splitting with {totalSelected} {totalSelected === 1 ? 'person' : 'people'}
            </Text>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.bubbleRow}>
              {currentUser && (
                <ParticipantBubble participant={currentUser} size={38} selected showName />
              )}
              {friends.filter(f => selectedFriendIds.has(f.id)).map(f => (
                <ParticipantBubble key={f.id} participant={f} size={38} selected showName />
              ))}
            </ScrollView>
          </View>
        )}

        <View style={{ height: 100 }} />
      </ScrollView>

      <View style={styles.bottomBar}>
        {!canContinue && (
          <Text style={styles.minHint}>Select at least 1 friend to continue</Text>
        )}
        <TouchableOpacity
          style={[styles.continueBtn, (!canContinue || persisting) && styles.continueBtnDisabled]}
          onPress={handleContinue}
          disabled={!canContinue || persisting}
          activeOpacity={0.85}
        >
          {persisting ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.continueBtnText}>
              Continue ({totalSelected} {totalSelected === 1 ? 'person' : 'people'}) →
            </Text>
          )}
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  scroll: {
    padding: 16,
    gap: 14,
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  sectionLabel: {
    fontSize: 12,
    fontWeight: '800',
    color: '#6B7280',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: 12,
  },
  ownerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
  },
  ownerInfo: {
    flex: 1,
    gap: 2,
  },
  ownerName: {
    fontSize: 17,
    fontWeight: '900',
    color: '#111827',
  },
  ownerEmail: {
    fontSize: 13,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  payerBadge: {
    marginTop: 4,
    alignSelf: 'flex-start',
    backgroundColor: '#E8F5E9',
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
  },
  payerBadgeText: {
    fontSize: 11,
    fontWeight: '800',
    color: BRAND,
  },
  ownerPlaceholder: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
  },
  ownerPlaceholderCircle: {
    width: 52,
    height: 52,
    borderRadius: 26,
    backgroundColor: '#F3F4F6',
  },
  ownerPlaceholderLines: {
    gap: 6,
  },
  shimmer: {
    height: 14,
    borderRadius: 7,
    backgroundColor: '#F3F4F6',
  },
  searchWrap: {
    marginBottom: 12,
  },
  searchInput: {
    backgroundColor: '#F9FAFB',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 10,
    fontSize: 15,
    fontWeight: '600',
    color: '#111827',
  },
  friendRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
    gap: 12,
    borderRadius: 10,
    paddingHorizontal: 6,
  },
  friendRowSelected: {
    backgroundColor: '#F0FBF0',
  },
  friendInfo: {
    flex: 1,
    gap: 2,
  },
  friendName: {
    fontSize: 15,
    fontWeight: '700',
    color: '#111827',
  },
  friendEmail: {
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  selCheckbox: {
    width: 22,
    height: 22,
    borderRadius: 11,
    borderWidth: 2,
    borderColor: '#D1D5DB',
    alignItems: 'center',
    justifyContent: 'center',
  },
  selCheckboxActive: {
    borderColor: BRAND,
    backgroundColor: BRAND,
  },
  selDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: '#fff',
  },
  noResults: {
    textAlign: 'center',
    color: '#9CA3AF',
    fontWeight: '600',
    fontSize: 14,
    paddingVertical: 16,
  },
  selectedPreviewCard: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 16,
    gap: 10,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  selectedPreviewLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: '#374151',
  },
  bubbleRow: {
    flexDirection: 'row',
    gap: 12,
  },
  bottomBar: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    backgroundColor: '#fff',
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
    padding: 16,
    paddingBottom: 32,
    gap: 8,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: -3 },
    shadowOpacity: 0.07,
    shadowRadius: 8,
    elevation: 8,
  },
  minHint: {
    textAlign: 'center',
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  continueBtn: {
    backgroundColor: BRAND,
    borderRadius: 14,
    paddingVertical: 16,
    alignItems: 'center',
  },
  continueBtnDisabled: {
    opacity: 0.45,
  },
  continueBtnText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 16,
  },
});
