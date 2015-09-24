'use strict'
var a = 2;
var b = 3;
if (!(a === 3)) {
  throw new Error("should-not-interfere failed");
}
module.exports = {};