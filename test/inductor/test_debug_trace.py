# Owner(s): ["module: inductor"]
import logging
import os
import pathlib
import re
import shutil
import sys
import unittest

import torch
from torch._inductor import config, test_operators
from torch.testing._internal.inductor_utils import GPU_TYPE, HAS_GPU

try:
    try:
        from . import test_torchinductor
    except ImportError:
        import test_torchinductor
except unittest.SkipTest:
    if __name__ == "__main__":
        sys.exit(0)
    raise


def filesize(filename: pathlib.Path):
    assert filename.exists(), f"{filename} is missing"
    return os.stat(filename).st_size


@config.patch("trace.enabled", True)
class TestDebugTrace(test_torchinductor.TestCase):
    def test_debug_trace(self):
        @torch.compile
        def fn(a, b):
            a = test_operators.realize(a + 1) + 2
            return torch.matmul(a, b)

        with self.assertLogs(
            logging.getLogger("torch._inductor.debug"), level=logging.WARNING
        ) as cm:
            fn(torch.randn(16, 16), torch.randn(16, 16))

        self.assertEqual(len(cm.output), 1)
        m = re.match(r"WARNING.* debug trace: (.*)", cm.output[0])
        self.assertTrue(m)
        filename = pathlib.Path(m.group(1))
        self.assertTrue(filename.is_dir())
        self.assertGreater(filesize(filename / "fx_graph_readable.py"), 512)
        self.assertGreater(filesize(filename / "fx_graph_runnable.py"), 512)
        self.assertGreater(filesize(filename / "fx_graph_transformed.py"), 512)
        self.assertGreater(filesize(filename / "output_code.py"), 1024)
        self.assertExpectedInline(
            open(filename / "ir_pre_fusion.txt").read().rstrip(),
            """\
buf0: SchedulerNode(ComputedBuffer)
buf0.writes = [MemoryDep('buf0', c0, {c0: 256}, None)]
buf0.unmet_dependencies = []
buf0.met_dependencies = [MemoryDep('arg0_1', c0, {c0: 256}, None)]
buf0.users = [NodeUser(node=SchedulerNode(name='buf1'), can_inplace=True, is_weak=False)]
buf0.group.device = cpu
buf0.group.iteration = ((256,), ())
buf0.sizes = ([256], [])
arg0_1_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
buf0_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
class buf0_loop_body:
    var_ranges = {y0: 256}
    index0 = y0
    def body(self, ops):
        get_index = self.get_index('index0')
        load = ops.load('arg0_1', get_index)
        constant = ops.constant(1.0, torch.float32)
        add = ops.add(load, constant)
        get_index_1 = self.get_index('index0')
        store = ops.store('buf0', get_index_1, add, None)
        return store


buf1: SchedulerNode(ComputedBuffer)
buf1.writes = [MemoryDep('buf1', c0, {c0: 256}, None)]
buf1.unmet_dependencies = [MemoryDep('buf0', c0, {c0: 256}, None)]
buf1.met_dependencies = []
buf1.users = [NodeUser(node=ExternKernelSchedulerNode(name='buf2'), can_inplace=False, is_weak=False)]
buf1.group.device = cpu
buf1.group.iteration = ((256,), ())
buf1.sizes = ([256], [])
buf0_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
buf1_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
class buf1_loop_body:
    var_ranges = {y0: 256}
    index0 = y0
    def body(self, ops):
        get_index = self.get_index('index0')
        load = ops.load('buf0', get_index)
        constant = ops.constant(2.0, torch.float32)
        add = ops.add(load, constant)
        get_index_1 = self.get_index('index0')
        store = ops.store('buf1', get_index_1, add, None)
        return store


buf2: ExternKernelSchedulerNode(ExternKernelOut)
buf2.writes = [StarDep(name='buf2', mode=None)]
buf2.unmet_dependencies = [StarDep(name='buf1', mode=None)]
buf2.met_dependencies = [StarDep(name='arg1_1', mode=None)]
buf2.users = [NodeUser(node=OUTPUT, can_inplace=False, is_weak=False)]
buf2.node.kernel = extern_kernels.mm""",
        )
        self.assertExpectedInline(
            open(filename / "ir_post_fusion.txt").read().rstrip(),
            """\
buf0_buf1: FusedSchedulerNode(SchedulerNode,SchedulerNode)
buf0_buf1.writes = [MemoryDep('buf0', c0, {c0: 256}, None), MemoryDep('buf1', c0, {c0: 256}, None)]
buf0_buf1.unmet_dependencies = []
buf0_buf1.met_dependencies = [MemoryDep('arg0_1', c0, {c0: 256}, None)]
buf0_buf1.users = []
    buf0_buf1.snodes[0] =
    buf0: SchedulerNode(ComputedBuffer)
    buf0.writes = [MemoryDep('buf0', c0, {c0: 256}, None)]
    buf0.unmet_dependencies = []
    buf0.met_dependencies = [MemoryDep('arg0_1', c0, {c0: 256}, None)]
    buf0.users = [NodeUser(node=SchedulerNode(name='buf1'), can_inplace=True, is_weak=False)]
    buf0.group.device = cpu
    buf0.group.iteration = ((256,), ())
    buf0.sizes = ([256], [])
    arg0_1_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
    buf0_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
    class buf0_loop_body:
        var_ranges = {y0: 256}
        index0 = y0
        def body(self, ops):
            get_index = self.get_index('index0')
            load = ops.load('arg0_1', get_index)
            constant = ops.constant(1.0, torch.float32)
            add = ops.add(load, constant)
            get_index_1 = self.get_index('index0')
            store = ops.store('buf0', get_index_1, add, None)
            return store
    buf0_buf1.snodes[1] =
    buf1: SchedulerNode(ComputedBuffer)
    buf1.writes = [MemoryDep('buf1', c0, {c0: 256}, None)]
    buf1.unmet_dependencies = [MemoryDep('buf0', c0, {c0: 256}, None)]
    buf1.met_dependencies = []
    buf1.users = [NodeUser(node=ExternKernelSchedulerNode(name='buf2'), can_inplace=False, is_weak=False)]
    buf1.group.device = cpu
    buf1.group.iteration = ((256,), ())
    buf1.sizes = ([256], [])
    buf0_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
    buf1_layout = FixedLayout('cpu', torch.float32, size=[16, 16], stride=[16, 1])
    class buf1_loop_body:
        var_ranges = {y0: 256}
        index0 = y0
        def body(self, ops):
            get_index = self.get_index('index0')
            load = ops.load('buf0', get_index)
            constant = ops.constant(2.0, torch.float32)
            add = ops.add(load, constant)
            get_index_1 = self.get_index('index0')
            store = ops.store('buf1', get_index_1, add, None)
            return store


buf2: ExternKernelSchedulerNode(ExternKernelOut)
buf2.writes = [StarDep(name='buf2', mode=None)]
buf2.unmet_dependencies = [StarDep(name='buf1', mode=None)]
buf2.met_dependencies = [StarDep(name='arg1_1', mode=None)]
buf2.users = [NodeUser(node=OUTPUT, can_inplace=False, is_weak=False)]
buf2.node.kernel = extern_kernels.mm""",
        )
        # intentionally only cleanup on success so debugging test is easier
        shutil.rmtree(filename)

    @unittest.skipIf(not HAS_GPU, "requires GPU")
    def test_debug_multi_tempalte(self):
        class ToyModel(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.l = torch.nn.Linear(100, 100)
                self.relu = torch.nn.ReLU()

            def forward(self, x):
                return self.relu(self.l(x))

        # no failure

        from torch._inductor.utils import fresh_inductor_cache

        with self.assertLogs(
            logging.getLogger("torch._inductor.debug"), level=logging.WARNING
        ), fresh_inductor_cache():
            m = ToyModel().to(device=GPU_TYPE)
            m = torch.compile(m, mode="max-autotune")
            input_tensor = torch.randn(100).to(device=GPU_TYPE)
            m(input_tensor)


if __name__ == "__main__":
    from torch._inductor.test_case import run_tests
    from torch.testing._internal.inductor_utils import HAS_CPU

    if HAS_CPU:
        run_tests(needs="filelock")
