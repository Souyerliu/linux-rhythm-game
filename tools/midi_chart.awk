# Standard MIDI format 0/1 reader and four-key chart generator.
# Input: decimal bytes from od -An -v -tu1. No awk extensions required.
function fail(message) { print "MIDI import error: " message > "/dev/stderr"; failed=1; exit 1 }
function byte() {
    if (pos > limit) fail("Truncated MIDI data")
    return bytes[pos++]
}
function uint(n,    value,i) {
    value=0
    for(i=0;i<n;i++) value=value*256+byte()
    return value
}
function tag(expected,    i) {
    for(i=1;i<=length(expected);i++) if(sprintf("%c",byte()) != substr(expected,i,1)) fail("Missing " expected " chunk")
}
function vlq(    value,i,b) {
    value=0
    for(i=0;i<4;i++) {
        b=byte(); value=value*128+b%128
        if(b<128) return value
    }
    fail("Invalid MIDI variable event_size number")
}
# Python-compatible nearest-even rounding at exact half milliseconds.
function rounded(x,    n) { n=int(x); return n+(x-n>0.5 || (x-n==0.5 && n%2)) }
function min(a,b) { return a<b?a:b }
function max(a,b) { return a>b?a:b }
function sort(a,left,right,    i,j,pivot,temp) {
    i=left; j=right; pivot=a[int((left+right)/2)]
    while(i<=j) {
        while(a[i]<pivot) i++
        while(a[j]>pivot) j--
        if(i<=j) { temp=a[i]; a[i++]=a[j]; a[j--]=temp }
    }
    if(left<j) sort(a,left,j)
    if(i<right) sort(a,i,right)
}
function milliseconds(tick,    low,high,middle) {
    low=1; high=tempo_count
    while(low<high) {
        middle=int((low+high+1)/2)
        if(tempo_ticks[middle]<=tick) low=middle; else high=middle-1
    }
    return rounded((tempo_start[low]+(tick-tempo_ticks[low])*tempos[tempo_ticks[low]]/division)/1000)
}
function json(s,    out,i,c) {
    out="\""
    for(i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if(c=="\\" || c=="\"") out=out "\\" c
        else if(c=="\n") out=out "\\n"
        else if(c=="\r") out=out "\\r"
        else if(c=="\t") out=out "\\t"
        else if(c ~ /[[:cntrl:]]/) out=out "?"
        else out=out c
    }
    return out "\""
}
function analyze(    t,i,ch,comma,p) {
    printf "{\"division\":%d,\"duration_ms\":%d,\"tempos\":[",division,milliseconds(end_tick)
    for(i=1;i<=tempo_count;i++) printf "%s[%g,%.6f]",(i>1?",":""),tempo_ticks[i]/division,60000000/tempos[tempo_ticks[i]]
    printf "],\"tracks\":["
    for(t=0;t<track_count;t++) {
        printf "%s{\"index\":%d,\"name\":%s,\"notes\":%d,\"channels\":{",t?",":"",t,json(names[t]),counts[t]
        comma=""
        for(ch=0;ch<16;ch++) if((t SUBSEP ch) in channels) { printf "%s\"%d\":%d",comma,ch,channels[t,ch]; comma="," }
        printf "},\"programs\":{"
        comma=""
        for(ch=0;ch<16;ch++) if((t SUBSEP ch) in programs) { printf "%s\"%d\":%d",comma,ch,programs[t,ch]; comma="," }
        printf "}}"
    }
    print "]}"
}
# 32-bit LCG: products stay below 2^53, so double precision is exact.
# All seeds 0..2^32-1 are accepted; this is a new, versioned seed sequence.
function random_index(n) { state=(state*1664525+1013904223)%4294967296; return int(state/4294967296*n) }
function shuffle(a,    i,j,temp) {
    for(i=4;i>1;i--) { j=1+random_index(i); temp=a[i]; a[i]=a[j]; a[j]=temp }
}
# Sparse easy melodies can leave whole phrases empty while piano continues.
# Keep every original head, then split the widest gaps with real piano onsets.
# This is independent of the random seed and never quantizes off-grid notes.
function fill_easy_piano(    n,t,tick,ms,i,k,size,target,left,right,distance,best,best_distance,count) {
    fill_track=-1; fill_added=0
    if(!random_mode || subdivisions!=1 || ENVIRON["MIDI_TRACK"]!="" || ENVIRON["MIDI_SUPPORT"]!="") return
    if(total*1000 >= milliseconds(end_tick)*1.5) return
    for(n=1;n<=note_count;n++) if(nt[n]!=track && nt[n]!=support && nc[n]!=9 && tolower(names[nt[n]]) ~ /piano/ && ticks[n]%division==0) {
        ms=milliseconds(ticks[n])
        if(ms>=2000) piano_counts[nt[n]]++
    }
    for(t=0;t<track_count;t++) if(piano_counts[t] && (fill_track<0 || piano_counts[t]>piano_counts[fill_track])) fill_track=t
    if(fill_track<0) return
    for(i=1;i<=total;i++) fill_kept[times[i]]=1
    for(n=1;n<=note_count;n++) if(nt[n]==fill_track && nc[n]!=9 && ticks[n]%division==0) {
        ms=milliseconds(ticks[n]); k=piano_notes[ms]
        if(ms>=2000 && (!k || pitches[n]>pitches[k])) piano_notes[ms]=n
    }
    for(ms in fill_kept) fill_union[ms]=1
    for(ms in piano_notes) fill_union[ms]=1
    for(ms in fill_union) fill_times[++size]=ms+0
    sort(fill_times,1,size)
    target=int(milliseconds(end_tick)*1.75/1000)
    count=total
    while(count<target) {
        right=milliseconds(end_tick)
        for(i=size;i>=1;i--) {
            ms=fill_times[i]
            if(ms in fill_kept) right=ms
            fill_right[i]=right
        }
        left=2000-minimum_gap; best=0; best_distance=-1
        for(i=1;i<=size;i++) {
            ms=fill_times[i]
            if(ms in fill_kept) { left=ms; continue }
            distance=min(ms-left,fill_right[i]-ms)
            if(distance>=minimum_gap && distance>best_distance) { best=i; best_distance=distance }
        }
        if(!best) break
        fill_kept[fill_times[best]]=1; fill_added++; count++
    }
    if(!fill_added) { fill_track=-1; return }
    # Lane balance is assigned after hold construction for random charts.
    total=0
    for(i=1;i<=size;i++) if(fill_times[i] in fill_kept) {
        times[++total]=fill_times[i]; lanes[total]=0
    }
}
# Rebalance unusually uneven automatic charts in four-second phrases. Keep
# ordinary charts intact; all replacements are real onsets on the chosen grid.
function balance_phrases(    i,n,t,ms,b,buckets,sum,squares,mean,variance,count,cap,floor_count,size,left,right,distance,best,best_score,removed,added) {
    if(!random_mode || subdivisions==1 || ENVIRON["MIDI_TRACK"]!="" || ENVIRON["MIDI_SUPPORT"]!="") return
    buckets=int(milliseconds(end_tick)/4000)+1
    for(i=1;i<=total;i++) phrase_counts[int(times[i]/4000)]++
    for(b=0;b<buckets;b++) { sum+=phrase_counts[b]; squares+=phrase_counts[b]^2 }
    mean=sum/buckets; variance=squares/buckets-mean^2
    if(mean<=0 || variance<=mean^2*0.55^2) return
    cap=subdivisions==2?18:28
    floor_count=subdivisions==2?10:16
    for(i=1;i<=total;i++) {
        ms=times[i]; phrase_original[ms]=1
        phrase_union[ms]=1
    }
    for(n=1;n<=note_count;n++) {
        t=nt[n]
        if(nc[n]==9 || (t!=track && t!=support && tolower(names[t]) !~ /piano|vocal|guitar/)) continue
        if(ticks[n]*subdivisions%division) continue
        ms=milliseconds(ticks[n]); if(ms<2000) continue
        phrase_union[ms]=1; phrase_source_tracks[t]=1
    }
    for(ms in phrase_union) phrase_times[++size]=ms+0
    sort(phrase_times,1,size)
    # Spread the retained original heads across each crowded phrase.
    for(b=0;b<buckets;b++) {
        count=0
        if(phrase_counts[b]<=cap) {
            for(i=1;i<=size;i++) if(int(phrase_times[i]/4000)==b && (phrase_times[i] in phrase_original)) {
                phrase_kept[phrase_times[i]]=1; count++
            }
        } else {
            while(count<cap) {
                right=(b+1)*4000
                for(i=size;i>=1;i--) {
                    ms=phrase_times[i]
                    if(int(ms/4000)!=b) continue
                    if(ms in phrase_kept) right=ms
                    phrase_right[i]=right
                }
                left=max(2000,b*4000); best=0; best_score=-1
                for(i=1;i<=size;i++) {
                    ms=phrase_times[i]
                    if(int(ms/4000)!=b) continue
                    if(ms in phrase_kept) { left=ms; continue }
                    if(!(ms in phrase_original)) continue
                    distance=min(ms-left,phrase_right[i]-ms)
                    if(distance>best_score) { best=i; best_score=distance }
                }
                if(!best) break
                phrase_kept[phrase_times[best]]=1; count++
            }
            removed+=phrase_counts[b]-count
        }
        phrase_counts[b]=count
    }
    # Fill the widest gaps in sparse phrases, respecting neighbours even
    # across phrase boundaries. Never create notes in a genuine MIDI rest.
    while(1) {
        right=milliseconds(end_tick)+minimum_gap
        for(i=size;i>=1;i--) {
            ms=phrase_times[i]
            if(ms in phrase_kept) right=ms
            phrase_right[i]=right
        }
        left=2000-minimum_gap; best=0; best_score=-1
        for(i=1;i<=size;i++) {
            ms=phrase_times[i]; b=int(ms/4000)
            if(ms in phrase_kept) { left=ms; continue }
            if(phrase_counts[b]>=floor_count) continue
            distance=min(ms-left,phrase_right[i]-ms)
            if(distance>=minimum_gap && distance>best_score) { best=i; best_score=distance }
        }
        if(!best) break
        ms=phrase_times[best]; phrase_kept[ms]=1
        phrase_counts[int(ms/4000)]++; added++
    }
    total=0
    for(i=1;i<=size;i++) if(phrase_times[i] in phrase_kept) {
        times[++total]=phrase_times[i]; lanes[total]=0
    }
    phrase_balanced=1; phrase_added=added+0; phrase_removed=removed+0
}
{
    for(field=1;field<=NF;field++) bytes[++size]=$field+0
}
END {
    if(failed) exit 1
    pos=1; limit=size
    tag("MThd"); header_size=uint(4)
    if(header_size<6 || header_size>size-8) fail("Invalid MIDI header")
    format=uint(2); track_count=uint(2); division=uint(2)
    if((format!=0 && format!=1) || !track_count || (format==0 && track_count!=1) || !division || division>=32768)
        fail("Only format 0/1 MIDI with a PPQN timebase is supported")
    pos=9+header_size; tempos[0]=500000
    for(t=0;t<track_count;t++) {
        limit=size; tag("MTrk"); track_size=uint(4); next_track=pos+track_size
        if(next_track>size+1) fail("Truncated MIDI track")
        limit=next_track-1; tick=0; running=0
        while(pos<next_track) {
            tick+=vlq(); status=byte()
            if(status>=128) running=status<240?status:0
            else if(running) { pos--; status=running }
            else fail("Invalid MIDI running status")
            if(status==255) {
                kind=byte(); event_size=vlq()
                if(event_size>limit-pos+1) fail("Truncated MIDI meta event")
                if(kind==3) { names[t]=""; for(i=0;i<event_size;i++) names[t]=names[t] sprintf("%c",bytes[pos+i]) }
                if(kind==81 && event_size==3) {
                    tempo=bytes[pos]*65536+bytes[pos+1]*256+bytes[pos+2]
                    if(!tempo) fail("Invalid MIDI tempo")
                    tempos[tick]=tempo
                }
                pos+=event_size
                if(kind==47) break
            } else if(status==240 || status==247) {
                event_size=vlq(); if(event_size>limit-pos+1) fail("Truncated MIDI SysEx event")
                pos+=event_size
            } else if(status<240) {
                kind=int(status/16)*16; channel=status%16
                pitch=byte(); velocity=(kind==192 || kind==208)?0:byte()
                if(pitch>=128 || velocity>=128) fail("Invalid MIDI channel event")
                key=t SUBSEP channel SUBSEP pitch
                if(kind==144 && velocity) {
                    n=++note_count; nt[n]=t; ticks[n]=tick; pitches[n]=pitch; velocities[n]=velocity; nc[n]=channel; ends[n]=tick
                    queue[key,++tail[key]]=n
                    counts[t]++; channels[t,channel]++
                    if(channel!=9) melodic[t]++
                } else if(kind==128 || (kind==144 && !velocity)) {
                    if(head[key]<tail[key]) { n=queue[key,++head[key]]; ends[n]=tick }
                } else if(kind==192) programs[t,channel]=pitch
            } else fail("Unsupported MIDI system event")
        }
        end_tick=max(end_tick,tick); pos=next_track
    }
    for(tick in tempos) tempo_ticks[++tempo_count]=tick+0
    sort(tempo_ticks,1,tempo_count)
    for(i=2;i<=tempo_count;i++) tempo_start[i]=tempo_start[i-1]+(tempo_ticks[i]-tempo_ticks[i-1])*tempos[tempo_ticks[i-1]]/division
    if(ENVIRON["MIDI_ACTION"]=="analyze") { analyze(); exit }
    random_mode=ENVIRON["MIDI_RANDOM"]+0
    track=ENVIRON["MIDI_TRACK"]; support=ENVIRON["MIDI_SUPPORT"]
    if(track=="") {
        best=-1; preferred=-1
        for(t=0;t<track_count;t++) if(melodic[t]) {
            if(best<0 || counts[t]>counts[best]) best=t
            if(tolower(names[t]) ~ /main|melody|lead/ && (preferred<0 || counts[t]>counts[preferred])) preferred=t
        }
        track=random_mode && preferred>=0?preferred:best
    }
    if(track<0 || track>=track_count) fail("Track index out of range or no melodic notes")
    track+=0
    if(random_mode && support=="") {
        best=-1
        for(t=0;t<track_count;t++) if(t!=track && melodic[t]) {
            bass=tolower(names[t]) ~ /bass/
            for(ch=0;ch<16;ch++) if((t SUBSEP ch) in programs && programs[t,ch]>=32 && programs[t,ch]<=39) bass=1
            if(bass && (best<0 || counts[t]>counts[best])) best=t
        }
        if(best>=0) support=best
    }
    if(support!="" && (support<0 || support>=track_count)) fail("Support track index out of range")
    subdivisions=ENVIRON["MIDI_GRID"]=="1"?1:(ENVIRON["MIDI_GRID"]=="1/2"?2:4)
    minimum_gap=300/subdivisions
    for(n=1;n<=note_count;n++) if(nt[n]==track && nc[n]!=9 && ticks[n]*subdivisions%division==0) {
        tick=ticks[n]; old=chosen[tick]
        if(!old || pitches[n]>pitches[old]) chosen[tick]=n
    }
    first=-1; last=-1
    for(tick in chosen) { if(first<0 || tick+0<first) first=tick+0; last=max(last,tick+0) }
    if(first>=0 && support!="") for(n=1;n<=note_count;n++) {
        tick=ticks[n]
        if(nt[n]!=support || nc[n]==9 || (tick>=first && tick<=last) || tick*subdivisions%division) continue
        bucket=int(tick/(division*2))
        if(!(bucket in support_buckets)) { support_buckets[bucket]=1; chosen[tick]=n }
    }
    for(tick in chosen) { selected_ticks[++selected_count]=tick+0; pitch_set[pitches[chosen[tick]]]=1 }
    if(!selected_count) fail("Selected track has no usable notes")
    sort(selected_ticks,1,selected_count)
    for(pitch in pitch_set) sorted_pitches[++pitch_count]=pitch+0
    sort(sorted_pitches,1,pitch_count)
    for(i=1;i<=pitch_count;i++) pitch_lane[sorted_pitches[i]]=min(3,int((i-1)*4/pitch_count))
    last_lane=-1
    for(i=1;i<=selected_count;i++) {
        n=chosen[selected_ticks[i]]; ms=milliseconds(ticks[n])
        if(ms<2000 || (total && ms-times[total]<minimum_gap)) continue
        lane=pitch_lane[pitches[n]]
        if(lane==last_lane) { repeats++; if(repeats>=2) { lane=(lane+1)%4; repeats=0 } }
        else repeats=0
        times[++total]=ms; lanes[total]=lane; last_lane=lane
    }
    if(!total) fail("Selected track has no usable notes")
    fill_easy_piano()
    balance_phrases()
    if(ENVIRON["MIDI_HOLDS"]+0) {
        for(n=1;n<=note_count;n++) if((nt[n]==track || (support!="" && nt[n]==support) || nt[n]==fill_track || (nt[n] in phrase_source_tracks)) && nc[n]!=9 && ends[n]>ticks[n]) {
            ms=milliseconds(ticks[n]); end=milliseconds(ends[n]); old=sources[ms]
            if(!old || end>milliseconds(ends[old])) sources[ms]=n
        }
        quota=int(total/5); last_index=-4; active_until=-1
        for(i=1;i<=total && hold_count<quota;i++) {
            start=times[i]; n=sources[start]
            if(!n || i-last_index<5 || start<=active_until) continue
            tick=ticks[n]; one_beat=milliseconds(tick+division)-start
            end=min(milliseconds(ends[n]),milliseconds(tick+division*2))
            if(i+2<=total) end=min(end,times[i+2]-300)
            if(!random_mode) for(j=i+1;j<=total;j++) if(lanes[j]==lanes[i]) { end=min(end,times[j]-300); break }
            low=0; high=int(ends[n]*subdivisions/division)
            while(low<high) {
                middle=int((low+high+1)/2)
                if(milliseconds(middle*division/subdivisions)<=end) low=middle; else high=middle-1
            }
            end=milliseconds(low*division/subdivisions)
            if(end-start<max(400,one_beat)) continue
            tails[i]=end; hold_count++; last_index=i; active_until=end
        }
    }
    if(random_mode) {
        state=ENVIRON["MIDI_SEED"]+0
        hand=random_index(2)
        for(i=1;i<=total;i++) {
            if((i-1)%8==0) {
                left[1]=left[2]=0; left[3]=left[4]=1
                right[1]=right[2]=2; right[3]=right[4]=3
                shuffle(left); shuffle(right); li=ri=4
            }
            lanes[i]=(hand+i-1)%2?right[ri--]:left[li--]
        }
    }
    print "# Four Keys chart v1"
    print "# audio=" ENVIRON["MIDI_AUDIO"]
    print "# offset_ms=0"
    for(i=1;i<=tempo_count;i++) {
        tick=tempo_ticks[i]; bpm=60000000/tempos[tick]; integer=rounded(bpm)
        if(tick%division || (bpm-integer>0.001 || integer-bpm>0.001) || integer<20 || integer>400)
            fail("Tempo map needs fractional beats/BPM, unsupported by CSV v1")
        if(i==1) printf "# bpm=%d\n",integer
        else printf "# tempo=%d,%d\n",tick/division+1,integer
    }
    if(random_mode) {
        print "# random_seed=" ENVIRON["MIDI_SEED"]
        print "# random_mode=" ENVIRON["MIDI_MODE"]
        print "# melody_track=" track
        print "# support_track=" (support==""?"None":support)
        if(fill_added) {
            print "# density_fill_track=" fill_track
            print "# density_added=" fill_added
        }
        if(phrase_balanced) {
            print "# density_balanced=phrases-v1"
            print "# density_added=" phrase_added
            print "# density_removed=" phrase_removed
        }
        if(ENVIRON["MIDI_HOLDS"]+0) print "# hold_count=" (hold_count+0)
        print "# rhythm_grid=" ENVIRON["MIDI_GRID"]
    }
    for(i=1;i<=total;i++) {
        if(times[i]>999999999 || tails[i]>999999999) fail("Chart time is out of range")
        printf "%d,%d",times[i],lanes[i]
        if(tails[i]) printf ",%d",tails[i]
        print ""
    }
    printf "Notes: %d (%d holds) | Track: %d, bass: %s\n",total,hold_count,track,support==""?"None":support > "/dev/stderr"
}
