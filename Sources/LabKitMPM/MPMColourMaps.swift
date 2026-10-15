import Foundation

// Colour-map LUT for FluidDiagnostic: 4 rows × 256 sRGB-encoded RGBA8 texels (sample through an `_srgb` texture).
// Rows: 0 viridis, 1 magma, 2 inferno, 3 plasma, generated with matplotlib 3.10.9 (`colormaps[name](i / 255)`, rounded).
// The four maps are by Nathaniel J. Smith and Stéfan van der Walt (viridis also by Eric Firing), released under CC0;
// credited in LabKit/THIRD_PARTY_NOTICES.md.
enum MPMColourMaps {
  static let rows = 4
  static let width = 256

  /// 4,096 bytes: row-major RGBA8, sRGB-encoded.
  static let bytes: [UInt8] = {
    let b64 = chunks.joined()
    guard let d = Data(base64Encoded: b64), d.count == rows * width * 4 else { return Array(repeating: 128, count: 4 * 256 * 4) }
    return [UInt8](d)
  }()

  private static let chunks: [String] = [
    "RAFU/0QCVv9FBFf/RQVZ/0YHWv9GCFz/Rgpd/0YLXv9HDWD/Rw5h/0cQY/9HEWT/RxNl/0gUZ/9IFmj/SBdp/0gYav9IGmz/SBtt/0gcbv9IHW//SB9w",
    "/0ggcf9IIXP/SCN0/0gkdf9IJXb/SCZ3/0goeP9IKXn/Ryp6/0csev9HLXv/Ry58/0cvff9GMH7/RjJ+/0Yzf/9GNID/RTWB/0U3gf9FOIL/RDmD/0Q6",
    "g/9EO4T/Qz2E/0M+hf9CP4X/QkCG/0JBhv9BQof/QUSH/0BFiP9ARoj/P0eI/z9Iif8+SYn/PkqJ/z5Miv89TYr/PU6K/zxPiv88UIv/O1GL/ztSi/86",
    "U4v/OlSM/zlVjP85Voz/OFiM/zhZjP83Woz/N1uN/zZcjf82XY3/NV6N/zVfjf80YI3/NGGN/zNijf8zY43/MmSO/zJljv8xZo7/MWeO/zFojv8waY7/",
    "MGqO/y9rjv8vbI7/Lm2O/y5ujv8ub47/LXCO/y1xjv8scY7/LHKO/yxzjv8rdI7/K3WO/yp2jv8qd47/KniO/yl5jv8peo7/KXuO/yh8jv8ofY7/J36O",
    "/yd/jv8ngI7/JoGO/yaCjv8mgo7/JYOO/yWEjv8lhY7/JIaO/ySHjv8jiI7/I4mO/yOKjf8ii43/IoyN/yKNjf8hjo3/IY+N/yGQjf8hkYz/IJKM/yCS",
    "jP8gk4z/H5SM/x+Vi/8flov/H5eL/x+Yi/8fmYr/H5qK/x6biv8enIn/Hp2J/x+eif8fn4j/H6CI/x+hiP8foYf/H6KH/yCjhv8gpIb/IaWF/yGmhf8i",
    "p4X/IqiE/yOpg/8kqoP/JauC/yWsgv8mrYH/J62B/yiugP8pr3//KrB//yyxfv8tsn3/LrN8/y+0fP8xtXv/MrZ6/zS2ef81t3n/N7h4/zi5d/86unb/",
    "O7t1/z28dP8/vHP/QL1y/0K+cf9Ev3D/RsBv/0jBbv9KwW3/TMJs/07Da/9QxGr/UsVp/1TFaP9Wxmf/WMdl/1rIZP9cyGP/Xsli/2DKYP9jy1//Zcte",
    "/2fMXP9pzVv/bM1a/27OWP9wz1f/c9BW/3XQVP930VP/etFR/3zSUP9/007/gdNN/4TUS/+G1Un/idVI/4vWRv+O1kX/kNdD/5PXQf+V2ED/mNg+/5vZ",
    "PP+d2Tv/oNo5/6LaN/+l2zb/qNs0/6rcMv+t3DD/sN0v/7LdLf+13iv/uN4p/7reKP+93yb/wN8l/8LfI//F4CH/yOAg/8rhH//N4R3/0OEc/9LiG//V",
    "4hr/2OIZ/9rjGf/d4xj/3+MY/+LkGP/l5Bn/5+QZ/+rlGv/s5Rv/7+Uc//HlHf/05h7/9uYg//jmIf/75yP//ecl/wAABP8BAAX/AQEG/wEBCP8CAQn/",
    "AgIL/wICDf8DAw//AwMS/wQEFP8FBBb/BgUY/wYFGv8HBhz/CAce/wkHIP8KCCL/Cwkk/wwJJv8NCin/Dgsr/xALLf8RDC//Eg0x/xMNNP8UDjb/FQ44",
    "/xYPO/8YDz3/GRA//xoQQv8cEET/HRFH/x4RSf8gEUv/IRFO/yIRUP8kElP/JRJV/ycSWP8pEVr/KhFc/ywRX/8tEWH/LxFj/zERZf8zEGf/NBBp/zYQ",
    "a/84EGz/OQ9u/zsPcP89D3H/Pw9y/0APdP9CD3X/RA92/0UQd/9HEHj/SRB4/0oQef9MEXr/ThF7/08Se/9REnz/UhN8/1QTff9WFH3/VxV+/1kVfv9a",
    "Fn7/XBZ//10Xf/9fGH//YBiA/2IZgP9kGoD/ZRqA/2cbgP9oHIH/ahyB/2sdgf9tHYH/bh6B/3Afgf9yH4H/cyCB/3Uhgf92IYH/eCKB/3kigv97I4L/",
    "fCOC/34kgv+AJYL/gSWB/4Mmgf+EJoH/hieB/4gngf+JKIH/iymB/4wpgf+OKoH/kCqB/5Ergf+TK4D/lCyA/5YsgP+YLYD/mS2A/5suf/+cLn//ni9/",
    "/6Avf/+hMH7/ozB+/6Uxfv+mMX3/qDJ9/6ozff+rM3z/rTR8/640e/+wNXv/sjV7/7M2ev+1Nnr/tzd5/7g3ef+6OHj/vDl4/705d/+/Onf/wDp2/8I7",
    "df/EPHX/xTx0/8c9c//IPnP/yj5y/8w/cf/NQHH/z0Bw/9BBb//SQm//00Nu/9VEbf/WRWz/2EVs/9lGa//bR2r/3Ehp/95JaP/fSmj/4Exn/+JNZv/j",
    "TmX/5E9k/+VQZP/nUmP/6FNi/+lUYv/qVmH/61dg/+xYYP/tWl//7lte/+9dXv/wX17/8WBd//JiXf/yZFz/82Vc//RnXP/0aVz/9Wtc//ZsXP/2blz/",
    "93Bc//dyXP/4dFz/+HZc//l4Xf/5eV3/+Xtd//p9Xv/6f17/+oFf//uDX//7hWD/+4dh//yJYf/8imL//Ixj//yOZP/8kGX//ZJm//2UZ//9lmj//Zhp",
    "//2aav/9m2v//p1s//6fbf/+oW7//qNv//6lcf/+p3L//qlz//6qdP/+rHb//q53//6weP/+snr//rR7//62fP/+t37//rl///67gf/+vYL//r+E//7B",
    "hf/+wof//sSI//7Giv/+yIz//sqN//7Mj//+zZD//s+S//7RlP/+05X//tWX//7Xmf/+2Jr//dqc//3cnv/93qD//eCh//3io//946X//eWn//3nqf/9",
    "6ar//eus//zsrv/87rD//PCy//zytP/89Lb//Pa4//z3uf/8+bv//Pu9//z9v/8AAAT/AQAF/wEBBv8BAQj/AgEK/wICDP8CAg7/AwIQ/wQDEv8EAxT/",
    "BQQX/wYEGf8HBRv/CAUd/wkGH/8KByL/Cwck/wwIJv8NCCn/Dgkr/xAJLf8RCjD/Egoy/xQLNP8VCzf/Fgs5/xgMPP8ZDD7/GwxB/xwMQ/8eDEX/HwxI",
    "/yEMSv8jDEz/JAxP/yYMUf8oC1P/KQtV/ysLV/8tC1n/Lwpb/zEKXP8yCl7/NApf/zYJYf84CWL/OQlj/zsJZP89CWX/Pglm/0AKZ/9CCmj/RApo/0UK",
    "af9HC2r/SQtq/0oMa/9MDGv/TQ1s/08NbP9RDmz/Ug5t/1QPbf9VD23/VxBu/1kQbv9aEW7/XBJu/10Sbv9fE27/YRNu/2IUbv9kFW7/ZRVu/2cWbv9p",
    "Fm7/ahdu/2wYbv9tGG7/bxlu/3EZbv9yGm7/dBpu/3Ubbv93HG3/eBxt/3odbf98HW3/fR5t/38ebP+AH2z/giBs/4Qga/+FIWv/hyFr/4giav+KImr/",
    "jCNp/40jaf+PJGn/kCVo/5IlaP+TJmf/lSZn/5cnZv+YJ2b/mihl/5spZP+dKWT/nypj/6AqY/+iK2L/oyxh/6UsYP+mLWD/qC5f/6kuXv+rL17/rTBd",
    "/64wXP+wMVv/sTJa/7MyWv+0M1n/tjRY/7c1V/+5NVb/ujZV/7w3VP+9OFP/vzlS/8A6Uf/BOlD/wztP/8Q8Tv/GPU3/xz5M/8g/S//KQEr/y0FJ/8xC",
    "SP/OQ0f/z0RG/9BFRf/SRkT/00dD/9RIQv/VSkH/10s//9hMPv/ZTT3/2k48/9tQO//dUTr/3lI4/99TN//gVTb/4VY1/+JXNP/jWTP/5Fox/+VcMP/m",
    "XS//514u/+hgLf/pYSv/6mMq/+tkKf/rZij/7Gcm/+1pJf/uaiT/72wj/+9uIf/wbyD/8XEf//FzHf/ydBz/83Yb//N4Gf/0eRj/9XsX//V9Ff/2fhT/",
    "9oAT//eCEv/3hBD/+IUP//iHDv/4iQz/+YsL//mMCv/5jgn/+pAI//qSB//6lAf/+5YG//uXBv/7mQb/+5sG//udB//8nwf//KEI//yjCf/8pQr//KYM",
    "//yoDf/8qg///KwR//yuEv/8sBT//LIW//y0GP/7thr/+7gd//u6H//7vCH/+74j//rAJv/6wij/+sQq//rGLf/5xy//+cky//nLNf/4zTf/+M86//fR",
    "Pf/300D/9tVD//bXRv/12Un/9dtM//TdT//031P/9OFW//PjWv/z5V3/8uZh//LoZf/y6mn/8ext//Htcf/x73X/8fF5//Lyff/y9IL/8/WG//P2iv/0",
    "+I7/9fmS//b6lv/4+5r/+fyd//r9of/8/6T/DQiH/xAHiP8TB4n/FgeK/xkGjP8bBo3/HQaO/yAGj/8iBpD/JAaR/yYFkf8oBZL/KgWT/ywFlP8uBZX/",
    "LwWW/zEFl/8zBZf/NQSY/zcEmf84BJr/OgSa/zwEm/8+BJz/PwSc/0EEnf9DA57/RAOe/0YDn/9IA5//SQOg/0sDof9MAqH/TgKi/1ACov9RAqP/UwKj",
    "/1UCpP9WAaT/WAGk/1kBpf9bAaX/XAGm/14Bpv9gAab/YQCn/2MAp/9kAKf/ZgCn/2cAqP9pAKj/agCo/2wAqP9uAKj/bwCo/3EAqP9yAaj/dAGo/3UB",
    "qP93Aaj/eAGo/3oCqP97Aqj/fQOo/34DqP+ABKj/gQSn/4MFp/+EBaf/hgam/4cHpv+ICKb/igml/4sKpf+NC6X/jgyk/48NpP+RDqP/kg+j/5QQov+V",
    "EaH/lhOh/5gUoP+ZFZ//mhaf/5wXnv+dGJ3/nhmd/6AanP+hG5v/oh2a/6Memv+lH5n/piCY/6chl/+oIpb/qiOV/6sklP+sJpT/rSeT/64okv+wKZH/",
    "sSqQ/7Irj/+zLI7/tC6N/7UvjP+2MIv/tzGK/7gyif+6M4j/uzSI/7w1h/+9N4b/vjiF/785hP/AOoP/wTuC/8I8gf/DPYD/xD5//8VAfv/GQX3/x0J8",
    "/8hDe//JRHr/ykV6/8tGef/MR3j/zEl3/81Kdv/OS3X/z0x0/9BNc//RTnL/0k9x/9NRcf/UUnD/1VNv/9VUbv/WVW3/11Zs/9hXa//ZWGr/2lpq/9pb",
    "af/bXGj/3F1n/91eZv/eX2X/3mFk/99iY//gY2P/4WRi/+JlYf/iZmD/42hf/+RpXv/lal3/5Wtd/+ZsXP/nblv/529a/+hwWf/pcVj/6XJX/+p0V//r",
    "dVb/63ZV/+x3VP/teVP/7XpS/+57Uf/vfFH/735Q//B/T//wgE7/8YFN//GDTP/yhEv/84VL//OHSv/0iEn/9IlI//WLR//1jEb/9o1F//aPRP/3kET/",
    "95FD//eTQv/4lEH/+JVA//mXP//5mD7/+Zo+//qbPf/6nDz/+p47//ufOv/7oTn/+6I4//yjOP/8pTf//KY2//yoNf/8qTT//asz//2sM//9rjL//a8x",
    "//2xMP/9si///bQv//21Lv/+ty3//rgs//66LP/+uyv//r0q//6+Kv/+wCn//cIp//3DKP/9xSf//cYn//3IJ//9yib//csm//zNJf/8ziX//NAl//zS",
    "Jf/70yT/+9Uk//vXJP/62CT/+tok//ncJP/53SX/+N8l//jhJf/34iX/9+Ql//bmJv/26Cb/9ekm//XrJ//07Sf/8+4n//PwJ//y8if/8fQm//H1Jf/w",
    "9yT/8Pkh/w==",
  ]
}
