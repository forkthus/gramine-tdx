# fio

Run from the parent directory:

```sh
cd ../
```

## CoVM path (via parent VM)

```sh
./run_fio_CoVM.sh -- --version
```

Example job:

```sh
./run_fio_CoVM.sh -- \
  --name=seqread \
  --filename=test.dat \
  --size=128M \
  --rw=read
```

Notes:
- `--filename` must use `--filename=<name>` form.
- The script rewrites filename to `/home/ubuntu/fio-data/<name>`.

## Upstream path (direct gramine-tdx)

```sh
./run_fio_upstream.sh -- --version
```

Example job:

```sh
./run_fio_upstream.sh -- \
  --name=randrw \
  --filename=fio.dat \
  --size=1G \
  --rw=randrw
```

Notes:
- `--filename` must use `--filename=<name>` form.
- The script rewrites filename to `$PWD/<name>`.

## Manual build (optional)

The wrappers already build/refresh artifacts as needed.  
If you want to build manually:

```sh
cd fio
./build_fio.sh
```
