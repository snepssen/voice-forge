#!/usr/bin/env python3
"""Add experimental per-token duration factors to a COPY of a Piper ONNX model.

No weights change. The existing predicted durations are multiplied immediately
before their frame rounding. A factor of one must preserve stock inference;
audition.mjs tests that against the original at several input lengths.

This recognizer deliberately supports only the inspected VITS graph pattern.
It fails closed on other exports instead of guessing which tensor is timing.
Requires onnx; reads the source and creates a new destination with exclusive open.
"""
import argparse
import hashlib
import json
from pathlib import Path

import onnx
from onnx import helper, TensorProto


def extend(source: Path, destination: Path):
    original = source.read_bytes()
    model = onnx.load_model_from_string(original)
    graph = model.graph
    if {v.name for v in graph.input} != {"input", "input_lengths", "scales"}:
        raise ValueError("Expected the single-speaker stock Piper input contract")
    candidates = [n for n in graph.node if n.op_type == "Ceil"]
    if len(candidates) != 1:
        raise ValueError("Expected one unambiguous duration-rounding node")
    target = candidates[0]
    producers = {value: n for n in graph.node for value in n.output}
    consumers = [n.op_type for n in graph.node if target.output[0] in n.input]
    prior = producers.get(target.input[0])
    if prior is None or prior.op_type != "Mul" or not {"ReduceSum", "CumSum"} <= set(consumers):
        raise ValueError("Ceil does not feed VITS frame count and alignment path")
    reserved = {"vf_duration_factors", "vf_base_frames", "vf_scaled_durations"}
    existing = {v.name for v in graph.input} | set(producers)
    if existing & reserved:
        raise ValueError("Model already contains experimental timing names")
    before = target.input[0]
    nodes = list(graph.node)
    index = next(i for i, n in enumerate(nodes) if n is target)
    target.input[0] = "vf_scaled_durations"
    nodes[index:index] = [
        helper.make_node("Ceil", [before], ["vf_base_frames"], name="vf_base_rounding"),
        helper.make_node("Mul", [before, "vf_duration_factors"],
                         ["vf_scaled_durations"], name="vf_duration_control"),
    ]
    del graph.node[:]
    graph.node.extend(nodes)
    shape = ["batch_size", 1, "phonemes"]
    graph.input.append(helper.make_tensor_value_info("vf_duration_factors", TensorProto.FLOAT, shape))
    for name in ["vf_base_frames", target.output[0]]:
        graph.output.append(helper.make_tensor_value_info(name, TensorProto.FLOAT, shape))
    onnx.checker.check_model(model)
    if destination.resolve() == source.resolve():
        raise ValueError("Output must be a separate experimental model")
    with destination.open("xb") as stream:
        stream.write(model.SerializeToString())
    print(json.dumps({"source": str(source), "sourceSHA256": hashlib.sha256(original).hexdigest(),
        "experimentalModel": str(destination), "durationOutput": target.output[0],
        "weightsUnchanged": True, "control": "multiply predicted token duration before ceil"}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    extend(args.source, args.destination)
