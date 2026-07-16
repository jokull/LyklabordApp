# Trace data attribution

## tsi-en-sample.json, tsi-distributions.json

Derived from the **Tap Typing with Touch Sensing Images (TSI)** dataset by
Google Research, licensed **CC-BY-4.0**.

- Repository: https://github.com/google-research-datasets/tap-typing-with-touch-sensing-images
- Paper: Piyawat Lertvittayakumjorn, Shanqing Cai, Billy Dou, Cedric Ho, Shumin Zhai.
  *Can Capacitive Touch Images Enhance Mobile Keyboard Decoding?* UIST '24.
  https://doi.org/10.1145/3654777.3676420

**What we derived:** we took the committed taps (`was_deleted == False`) from
`touch_data.csv`, grouped them into per-phrase typing traces, and normalized each
tap's pixel centroid into a within-key offset using the key geometry in the
dataset's `keyboard_data.json`. Inter-key timing is the original per-tap timestamp
delta. No capacitive heatmaps, touch-ellipse, or language-model score columns were
retained. This is a transformation of CC-BY-4.0 data and is redistributed under the
same license with the attribution above.

## synthetic-is.json

**Synthetic** Icelandic traces — clearly labeled `"synthetic": true`. Intended
sentences come from `data/eval/sentences.is.txt` (this repo's own eval corpus,
read-only). Timing is sampled from the TSI inter-key-gap distribution and spatial
noise is Gaussian with σ fit from the TSI within-key offset distribution. These
contain no human data from any Icelandic subject (no such dataset exists — see
research/typing-datasets.md) and must never be mixed into human-trace metrics.

## BibTeX

```
@inproceedings{10.1145/3654777.3676420,
  author = {Lertvittayakumjorn, Piyawat and Cai, Shanqing and Dou, Billy and Ho, Cedric and Zhai, Shumin},
  title = {Can Capacitive Touch Images Enhance Mobile Keyboard Decoding?},
  year = {2024},
  booktitle = {Proceedings of the 37th Annual ACM Symposium on User Interface Software and Technology},
  series = {UIST '24},
  doi = {10.1145/3654777.3676420}
}
```
