# Dev helpers

Not part of `run.sh`; used while building the spike. Run inside the image:

```sh
docker run --rm -v "$PWD":/spike -v ph-linux-ui-cache:/cache playhouse-linux-ui bash /spike/scripts/dev-compare.sh   # rebuild + native|SCUI|Adwaita strip
docker run --rm -v "$PWD":/spike -v ph-linux-ui-cache:/cache playhouse-linux-ui bash /spike/scripts/dev-probe.sh 500 # one startup run each
docker run --rm -e VARIANTS="full noclock nometer" -e COUNTS="50 100 200" -v "$PWD":/spike -v ph-linux-ui-cache:/cache playhouse-linux-ui bash /spike/scripts/dev-scale.sh
```
