# semphysdat <img height=100 widht=100 align=right src=https://raw.githubusercontent.com/LabNeuroCogDevel/semphysdat/master/icon.png>

Utility to chop physio measures from Semian's scanner by MR times and generate RVT regressors for a single MR protocol with AFNI's `RetroTS.m`

This is for you, if you want  `1D` inputs for `3dretroicor` or `afni_proc.py` (`ricor` block) and have physio recordings (.resp and .puls) files the look like [this](data/wpc4951_10824_20111108_110811.puls):

```
1 2 40 280 ...
ECG  Freq Per: 0 0
PULS Freq Per: 74 807
RESP Freq Per: 20 2860
....
6003
```


## Install

```bash
cpanm App::AFNI::SemainsPhysio
```

Hint: get [cpanm](http://search.cpan.org/~miyagawa/App-cpanminus-1.7019/lib/App/cpanminus.pm) like `curl -L https://cpanmin.us | perl - --sudo App::cpanminus`

### From this source
```bash
dzil build
dzil install
```

## Usage

```bash
seamphysdat respfile pulsefile MRdir
```

look for new `*dat` (chopped physio) and `*slibase.1D` (RVT regressors) files

see `perldoc semphysdat`


## Trouble Shooting
### RetroTS.m in path
You should have [afni's matlab scripts](http://afni.nimh.nih.gov/afni/matlab/) and they should be your [`MATLABPATH`](http://www.mathworks.com/help/matlab/ref/path.html) (e.g. `export MATLABPATH="$HOME/afni_matlab:$MATLABPATH"`)

### Example/Practice
try data included in [`data/`](data/). NB. will not work b/c MR count is wrong
