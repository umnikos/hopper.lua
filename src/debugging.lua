local pretty_print
function pprint(...)
  pretty_print = pretty_print or require("cc.pretty").pretty_print
  return pretty_print(...)
end
