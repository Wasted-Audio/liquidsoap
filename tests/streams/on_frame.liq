#!../../src/liquidsoap ../../libs/pervasives.liq

%include "test.liq"

set("log.level", 4)

n = ref(0)

def f()
  n := !n+1
  print("Frame #{!n}")
  if !n > 10 then
    test.pass()
    shutdown()
  end
end

s = sine()
s = source.on_frame(s,f)

output.dummy(s)
