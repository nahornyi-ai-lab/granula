
## WER % (CER %)

| engine | clean ru | clean uk | clean en | call ru | call uk | call en | long ru | long uk | long en | codeswitch ru+en | codeswitch uk+en |
|---|---|---|---|---|---|---|---|---|---|---|---|
| apple-dictation | 10.3 (2.7) | 13.5 (6.6) | 11.9 (5.8) | 11.0 (2.8) | 15.0 (6.9) | 13.3 (6.9) | 14.6 (5.0) | 17.4 (10.5) | 14.0 (7.8) | 63.5 (56.3) | 53.0 (51.0) |
| canary-1b-v2 | 10.1 (2.9) | 18.5 (6.9) | 5.8 (2.2) | 9.4 (3.3) | 21.3 (8.6) | 7.6 (3.6) | 16.2 (8.6) | 26.2 (16.2) | 17.3 (13.4) | 67.1 (64.2) | 59.5 (52.4) |
| gigaam-multilingual-large-ctc | 6.7 (4.4) | 79.5 (26.9) | 10.1 (4.7) | 7.2 (4.5) | 79.4 (27.3) | 11.2 (5.0) | 9.9 (6.5) | 88.6 (58.8) | 34.9 (27.3) | 34.2 (29.5) | 73.6 (44.6) |
| gigaam-v3-e2e-rnnt | 5.1 (1.2) | — | — | 5.0 (1.4) | — | — | 5.3 (1.4) | — | — | 48.4 (31.1) | — |
| parakeet-ultra | 6.2 (2.0) | 9.4 (2.5) | 5.5 (2.1) | 6.3 (2.5) | 10.1 (3.0) | 5.7 (2.2) | 7.8 (3.3) | 10.9 (3.4) | 4.6 (1.8) | 18.3 (12.6) | 18.7 (13.8) |
| parakeet-v3 | 6.6 (2.4) | 10.1 (3.4) | 5.6 (2.9) | 7.8 (2.7) | 10.2 (3.2) | 6.4 (3.0) | 7.2 (3.3) | 10.1 (2.9) | 5.3 (3.3) | 18.8 (15.8) | 26.4 (20.7) |
| parakeet-v3-hint | 6.8 (2.4) | 10.1 (3.4) | 5.6 (2.9) | 8.1 (2.8) | 10.2 (3.2) | 6.4 (3.0) | 6.8 (3.6) | 10.1 (3.2) | 5.3 (3.3) | 18.8 (15.8) | 26.4 (20.7) |
| qwen3-asr-0.6b-auto | 17.1 (7.2) | 90.2 (40.0) | 6.2 (2.7) | 22.6 (10.3) | 96.2 (46.6) | 10.1 (6.8) | 19.1 (7.9) | 94.3 (51.0) | 10.4 (6.5) | 34.2 (26.9) | 79.6 (59.5) |
| qwen3-asr-0.6b-forced | 16.4 (6.9) | 90.2 (40.0) | 6.4 (2.8) | 22.3 (10.4) | 96.2 (46.6) | 10.6 (6.9) | — | — | — | 34.2 (24.7) | 80.1 (59.8) |
| whisper-large-v3-auto | — | — | — | — | — | — | — | — | — | 57.0 (50.2) | 51.3 (46.0) |
| whisper-large-v3-forced | 4.1 (1.2) | 6.5 (1.8) | 4.6 (2.2) | 4.7 (1.4) | 6.9 (2.1) | 4.6 (2.5) | 27.5 (24.8) | 52.5 (41.4) | 34.4 (31.4) | 65.0 (57.8) | 55.9 (49.4) |
| whisper-large-v3-forced-chunk28 | — | — | — | — | — | — | 6.2 (2.2) | 20.7 (15.8) | 5.3 (3.0) | — | — |
| whisper-large-v3-forced-vad | — | — | — | — | — | — | 5.8 (1.9) | 42.4 (37.8) | 70.0 (70.4) | — | — |
| whisper-turbo-auto | 4.2 (1.2) | 6.6 (2.0) | 4.5 (1.6) | 4.7 (1.4) | 6.9 (1.8) | 5.1 (2.1) | 4.3 (1.6) | 34.7 (27.6) | 8.2 (5.3) | 52.0 (46.5) | 50.1 (42.2) |
| whisper-turbo-forced | 4.2 (1.2) | 6.6 (2.0) | 4.5 (1.6) | 4.7 (1.4) | 6.9 (1.8) | 5.1 (2.1) | 4.3 (1.6) | 34.7 (27.6) | 8.2 (5.3) | 40.6 (35.8) | 44.6 (37.8) |
| whisper-turbo-forced-chunk28 | — | — | — | — | — | — | 4.9 (2.0) | 15.6 (9.4) | 4.6 (2.3) | — | — |
| whisper-turbo-forced-vad | — | — | — | — | — | — | 5.3 (1.7) | 42.2 (37.8) | 70.8 (70.4) | — | — |

## Speed (RTF = processing time / audio time; lower is faster)

| engine | RTF short clean (all langs) | long ru RTF | long uk RTF | long en RTF | long total proc s |
|---|---|---|---|---|---|
| apple-dictation | 0.021 | 0.012 | 0.010 | 0.027 | 14.4 |
| canary-1b-v2 | 0.067 | 0.077 | 0.070 | 0.063 | 60.8 |
| gigaam-multilingual-large-ctc | 0.021 | 0.020 | 0.017 | 0.019 | 16.1 |
| gigaam-v3-e2e-rnnt | 0.038 | 0.035 | — | — | 10.6 |
| parakeet-ultra | 0.006 | 0.002 | 0.002 | 0.003 | 2.2 |
| parakeet-v3 | 0.006 | 0.002 | 0.002 | 0.003 | 2.2 |
| parakeet-v3-hint | 0.006 | 0.002 | 0.002 | 0.003 | 2.2 |
| qwen3-asr-0.6b-auto | 0.129 | 0.125 | 0.140 | 0.090 | 103.5 |
| qwen3-asr-0.6b-forced | 0.131 | — | — | — | 0.0 |
| whisper-large-v3-auto | — | — | — | — | 0.0 |
| whisper-large-v3-forced | 0.159 | 0.185 | 0.104 | 0.149 | 128.1 |
| whisper-large-v3-forced-chunk28 | — | 0.110 | 0.117 | 0.088 | 91.7 |
| whisper-large-v3-forced-vad | — | 0.087 | 0.070 | 0.025 | 53.3 |
| whisper-turbo-auto | 0.131 | 0.037 | 0.043 | 0.042 | 35.5 |
| whisper-turbo-forced | 0.091 | 0.036 | 0.042 | 0.040 | 34.1 |
| whisper-turbo-forced-chunk28 | — | 0.048 | 0.049 | 0.044 | 41.0 |
| whisper-turbo-forced-vad | — | 0.030 | 0.022 | 0.011 | 18.5 |

## Language ID (correct / n)

- whisper-large-v3-auto codeswitch ru+en: 10/15 ru:5
- whisper-large-v3-auto codeswitch uk+en: 5/10 uk:5
- whisper-large-v3-forced clean ru: 40/40 
- whisper-large-v3-forced clean uk: 40/40 
- whisper-large-v3-forced clean en: 40/40 
- whisper-large-v3-forced call ru: 40/40 
- whisper-large-v3-forced call uk: 40/40 
- whisper-large-v3-forced call en: 40/40 
- whisper-large-v3-forced long ru: 1/1 
- whisper-large-v3-forced long uk: 1/1 
- whisper-large-v3-forced long en: 1/1 
- whisper-large-v3-forced codeswitch ru+en: 10/15 ru:5
- whisper-large-v3-forced codeswitch uk+en: 5/10 uk:5
- whisper-large-v3-forced-chunk28 long ru: 1/1 
- whisper-large-v3-forced-chunk28 long uk: 1/1 
- whisper-large-v3-forced-chunk28 long en: 1/1 
- whisper-large-v3-forced-vad long ru: 1/1 
- whisper-large-v3-forced-vad long uk: 1/1 
- whisper-large-v3-forced-vad long en: 1/1 
- whisper-turbo-auto clean ru: 40/40 
- whisper-turbo-auto clean uk: 40/40 
- whisper-turbo-auto clean en: 40/40 
- whisper-turbo-auto call ru: 40/40 
- whisper-turbo-auto call uk: 40/40 
- whisper-turbo-auto call en: 40/40 
- whisper-turbo-auto long ru: 1/1 
- whisper-turbo-auto long uk: 1/1 
- whisper-turbo-auto long en: 1/1 
- whisper-turbo-auto codeswitch ru+en: 9/15 en:2;ru:4
- whisper-turbo-auto codeswitch uk+en: 6/10 uk:4
- whisper-turbo-forced clean ru: 40/40 
- whisper-turbo-forced clean uk: 40/40 
- whisper-turbo-forced clean en: 40/40 
- whisper-turbo-forced call ru: 40/40 
- whisper-turbo-forced call uk: 40/40 
- whisper-turbo-forced call en: 40/40 
- whisper-turbo-forced long ru: 1/1 
- whisper-turbo-forced long uk: 1/1 
- whisper-turbo-forced long en: 1/1 
- whisper-turbo-forced codeswitch ru+en: 9/15 en:2;ru:4
- whisper-turbo-forced codeswitch uk+en: 6/10 uk:4
- whisper-turbo-forced-chunk28 long ru: 1/1 
- whisper-turbo-forced-chunk28 long uk: 1/1 
- whisper-turbo-forced-chunk28 long en: 1/1 
- whisper-turbo-forced-vad long ru: 1/1 
- whisper-turbo-forced-vad long uk: 1/1 
- whisper-turbo-forced-vad long en: 1/1 

## Code-switch verdicts

- apple-dictation: {'ru+en:en_part_lost': 10, 'uk+en:en_part_lost': 5, 'en+ru:slavic_part_lost_translated_to_en': 3, 'en+ru:slavic_part_lost': 2, 'en+uk:slavic_part_lost': 4, 'en+uk:slavic_part_lost_translated_to_en': 1}  mean recall slavic=0.53 en=0.36
- canary-1b-v2: {'ru+en:en_part_lost_translated_or_transliterated': 10, 'uk+en:en_part_lost': 2, 'uk+en:en_part_lost_translated_or_transliterated': 3, 'en+ru:slavic_part_lost_translated_to_en': 4, 'en+ru:both_lost': 1, 'en+uk:slavic_part_lost_translated_to_en': 5}  mean recall slavic=0.53 en=0.34
- gigaam-multilingual-large-ctc: {'ru+en:ok': 5, 'ru+en:partial': 2, 'ru+en:en_part_lost': 3, 'uk+en:both_lost': 3, 'uk+en:partial': 1, 'uk+en:slavic_part_lost': 1, 'en+ru:en_part_lost': 3, 'en+ru:en_part_lost_translated_or_transliterated': 1, 'en+ru:ok': 1, 'en+uk:both_lost': 2, 'en+uk:slavic_part_lost': 3}  mean recall slavic=0.63 en=0.38
- gigaam-v3-e2e-rnnt: {'ru+en:partial': 3, 'ru+en:en_part_lost': 7, 'en+ru:en_part_lost': 3, 'en+ru:partial': 2}  mean recall slavic=0.94 en=0.17
- parakeet-ultra: {'ru+en:ok': 8, 'ru+en:en_part_lost': 2, 'uk+en:en_part_lost': 2, 'uk+en:ok': 3, 'en+ru:ok': 3, 'en+ru:en_part_lost': 2, 'en+uk:ok': 4, 'en+uk:partial': 1}  mean recall slavic=0.93 en=0.69
- parakeet-v3: {'ru+en:ok': 8, 'ru+en:en_part_lost': 2, 'uk+en:en_part_lost': 3, 'uk+en:ok': 2, 'en+ru:ok': 4, 'en+ru:en_part_lost_translated_or_transliterated': 1, 'en+uk:ok': 3, 'en+uk:partial': 1, 'en+uk:slavic_part_lost': 1}  mean recall slavic=0.87 en=0.71
- parakeet-v3-hint: {'ru+en:ok': 8, 'ru+en:en_part_lost': 2, 'uk+en:en_part_lost': 3, 'uk+en:ok': 2, 'en+ru:ok': 4, 'en+ru:en_part_lost_translated_or_transliterated': 1, 'en+uk:ok': 3, 'en+uk:partial': 1, 'en+uk:slavic_part_lost': 1}  mean recall slavic=0.87 en=0.71
- qwen3-asr-0.6b-auto: {'ru+en:en_part_lost': 3, 'ru+en:ok': 5, 'ru+en:partial': 1, 'ru+en:en_part_lost_translated_or_transliterated': 1, 'uk+en:both_lost': 4, 'uk+en:slavic_part_lost': 1, 'en+ru:ok': 2, 'en+ru:en_part_lost_translated_or_transliterated': 1, 'en+ru:partial': 1, 'en+ru:en_part_lost': 1, 'en+uk:both_lost': 3, 'en+uk:slavic_part_lost': 2}  mean recall slavic=0.54 en=0.42
- qwen3-asr-0.6b-forced: {'ru+en:en_part_lost': 3, 'ru+en:ok': 6, 'ru+en:en_part_lost_translated_or_transliterated': 1, 'uk+en:both_lost': 4, 'uk+en:slavic_part_lost': 1, 'en+ru:ok': 1, 'en+ru:en_part_lost_translated_or_transliterated': 2, 'en+ru:partial': 1, 'en+ru:en_part_lost': 1, 'en+uk:both_lost': 3, 'en+uk:slavic_part_lost_translated_to_en': 1, 'en+uk:slavic_part_lost': 1}  mean recall slavic=0.55 en=0.41
- whisper-large-v3-auto: {'ru+en:en_part_lost_translated_or_transliterated': 2, 'ru+en:en_part_lost': 8, 'uk+en:en_part_lost': 5, 'en+ru:en_part_lost': 4, 'en+ru:en_part_lost_translated_or_transliterated': 1, 'en+uk:en_part_lost_translated_or_transliterated': 2, 'en+uk:ok': 1, 'en+uk:en_part_lost': 2}  mean recall slavic=0.94 en=0.04
- whisper-large-v3-forced: {'ru+en:en_part_lost_translated_or_transliterated': 2, 'ru+en:en_part_lost': 8, 'uk+en:en_part_lost': 5, 'en+ru:slavic_part_lost_translated_to_en': 5, 'en+uk:slavic_part_lost_translated_to_en': 5}  mean recall slavic=0.59 en=0.39
- whisper-turbo-auto: {'ru+en:en_part_lost': 5, 'ru+en:slavic_part_lost_translated_to_en': 1, 'ru+en:en_part_lost_translated_or_transliterated': 2, 'ru+en:ok': 1, 'ru+en:slavic_part_lost': 1, 'uk+en:en_part_lost': 4, 'uk+en:ok': 1, 'en+ru:en_part_lost': 4, 'en+ru:slavic_part_lost_translated_to_en': 1, 'en+uk:en_part_lost': 4, 'en+uk:slavic_part_lost_translated_to_en': 1}  mean recall slavic=0.80 en=0.22
- whisper-turbo-forced: {'ru+en:en_part_lost': 6, 'ru+en:ok': 2, 'ru+en:en_part_lost_translated_or_transliterated': 2, 'uk+en:en_part_lost': 4, 'uk+en:ok': 1, 'en+ru:ok': 4, 'en+ru:slavic_part_lost_translated_to_en': 1, 'en+uk:slavic_part_lost_translated_to_en': 4, 'en+uk:ok': 1}  mean recall slavic=0.77 en=0.49

## Clean speed pass on long-form files (RTF = processing / audio; x-real-time = 1/RTF)

| engine | ru RTF | uk RTF | en RTF | total audio s | total proc s | x real-time | peak RSS MB |
|---|---|---|---|---|---|---|---|
| apple-dictation | 0.012 | 0.011 | 0.029 | 871 | 15.0 | 58x | 22 |
| canary-1b-v2 | 0.076 | 0.069 | 0.063 | 871 | 60.6 | 14x | 947 |
| gigaam-multilingual-large-ctc | 0.012 | 0.012 | 0.012 | 871 | 10.4 | 83x | 5163 |
| gigaam-v3-e2e-rnnt | 0.033 | — | — | 302 | 10.0 | 30x | 2187 |
| parakeet-ultra | 0.002 | 0.002 | 0.003 | 871 | 2.1 | 409x | 143 |
| parakeet-v3 | 0.002 | 0.002 | 0.003 | 871 | 2.2 | 399x | 143 |
| qwen3-asr-0.6b-auto | 0.128 | 0.139 | 0.089 | 871 | 103.7 | 8x | 2195 |
| whisper-large-v3-forced-chunk28 | 0.107 | 0.116 | 0.087 | 871 | 90.0 | 10x | 4227 |
| whisper-large-v3-forced-vad | 0.086 | 0.070 | 0.025 | 871 | 53.2 | 16x | 4217 |
| whisper-large-v3-forced | 0.185 | 0.103 | 0.149 | 871 | 127.6 | 7x | 4159 |
| whisper-turbo-forced-chunk28 | 0.048 | 0.050 | 0.044 | 871 | 41.4 | 21x | 2108 |
| whisper-turbo-forced-vad | 0.030 | 0.022 | 0.011 | 871 | 18.5 | 47x | 2148 |
| whisper-turbo-forced | 0.036 | 0.042 | 0.040 | 871 | 34.0 | 26x | 2147 |
