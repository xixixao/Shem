'use strict'
var Module__A = (function (){
var Some__Module = (function (){
var g = λ1(function g(x){
return x;
});
var f = λ1(function f(x){
return x;
});
return {"g": g};
}());
return {"Some__Module": Some__Module};
}());
var i0 = Module__A.Some__Module;
var g = i0.g;
var f = λ1(function f(x){
return g(x);
});
module.exports = {"f": f};