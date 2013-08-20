# define the convict config-schema
module.exports =
  protocol:
    doc: "On of the listet protocols of \"pilight-send --help\""
    format: String
    default: null
  outletUnit:
    doc: "The \"-u\ option of \"pilight-send\""
    format: "int"
    default: null
  outletId:
    doc: "The \"-i\ option of \"pilight-send\""
    format: "int"
    default: null
