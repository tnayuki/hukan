// SPDX-License-Identifier: GPL-2.0
// Place virtio-gpu's host-visible blobs on 64K boundaries, so a host whose
// pages are larger than the guest's (16K on Apple silicon) can map them.
// The stock driver calls drm_mm_insert_node(), an inline that passes
// alignment 0 down to drm_mm; this probe rewrites that argument for calls
// coming from the virtio_gpu module and no others. The function underneath
// that inline is drm_mm_insert_node_in_range(), whose fourth argument is the
// alignment.
#include <linux/kallsyms.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/sizes.h>

static int align_pre(struct kprobe *p, struct pt_regs *regs)
{
	char caller[KSYM_SYMBOL_LEN];

	if (regs->regs[3] != 0)
		return 0;

	/* "symbol+0x.../0x... [module]"; the module's own lookup is not exported. */
	sprint_symbol(caller, regs->regs[30]);
	if (strstr(caller, "[virtio_gpu]"))
		regs->regs[3] = SZ_64K;
	return 0;
}

static struct kprobe align_probe = {
	.symbol_name = "drm_mm_insert_node_in_range",
	.pre_handler = align_pre,
};

static int __init align_init(void)
{
	return register_kprobe(&align_probe);
}

static void __exit align_exit(void)
{
	unregister_kprobe(&align_probe);
}

module_init(align_init);
module_exit(align_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("64K alignment for virtio-gpu host-visible blobs");
