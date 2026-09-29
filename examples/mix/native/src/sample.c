#include "erl_nif.h"
#include "answer.h"
static ERL_NIF_TERM answer(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  return enif_make_int(env, sample_answer());
}
static ErlNifFunc funcs[] = {{"answer", 0, answer, 0}};
ERL_NIF_INIT(Elixir.SampleNative, funcs, NULL, NULL, NULL, NULL)
